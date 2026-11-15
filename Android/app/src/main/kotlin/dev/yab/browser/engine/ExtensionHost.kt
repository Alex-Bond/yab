package dev.yab.browser.engine

import java.net.URI
import java.util.Collections
import java.util.IdentityHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.WebExtension

data class ExtensionActionRow(val id: String, val extensionId: String, val title: String, val badge: String, val enabled: Boolean)

/** Signed external extensions use real Gecko tabs/actions. The app-owned built-in bridge is separate. */
class ExtensionHost(
    private val runtime: GeckoRuntime,
    private val canUse: () -> Boolean,
    private val newTab: (WebExtension, WebExtension.CreateTabDetails) -> GeckoSession?,
    private val closeTab: (GeckoSession) -> Boolean,
    private val updateTab: (GeckoSession, WebExtension.UpdateTabDetails) -> Boolean,
    private val configureSheet: (GeckoSession) -> Unit = {},
) {
    private val registered = linkedMapOf<String, WebExtension>()
    private val sessions = Collections.newSetFromMap(IdentityHashMap<GeckoSession, Boolean>())
    private data class Key(val id: String, val kind: String, val session: GeckoSession?)
    private val actions = mutableMapOf<Key, WebExtension.Action>()
    private var active: GeckoSession? = null
    private val mutableRows = MutableStateFlow(emptyList<ExtensionActionRow>())
    val rows: StateFlow<List<ExtensionActionRow>> = mutableRows
    private val mutablePopup = MutableStateFlow<GeckoSession?>(null)
    val popup: StateFlow<GeckoSession?> = mutablePopup
    private val mutableTitle = MutableStateFlow("")
    val popupTitle: StateFlow<String> = mutableTitle
    private var popupExtension: String? = null

    fun register(extension: WebExtension) {
        val metadata = extension.metaData
        if (extension.isBuiltIn || metadata == null || metadata.temporary || metadata.signedState < WebExtension.SignedStateFlags.PRELIMINARY) return
        registered[extension.id] = extension
        extension.setTabDelegate(object : WebExtension.TabDelegate {
            override fun onNewTab(source: WebExtension, createDetails: WebExtension.CreateTabDetails): GeckoResult<GeckoSession>? {
                if (!permitted(source) || !safeExtensionNavigation(source, createDetails.url)) return null
                if (createDetails.url?.let { ownExtensionUrl(source, it) } == true) {
                    // Extension pages are managed directly, without the address
                    // field reclassifying moz-extension: as a search query.
                    val sheet = makeSheet(source, source.metaData?.name ?: source.id, open = false) ?: return null
                    return GeckoResult.fromValue(sheet)
                }
                val session = newTab(source, createDetails) ?: return null
                // Gecko opens this returned session and loads createDetails.url itself.
                if (session.isOpen || session.settings.usePrivateMode) return null
                attach(session)
                return GeckoResult.fromValue(session)
            }
            override fun onOpenOptionsPage(source: WebExtension) { if (permitted(source)) openOptions(source.id) }
        })
        extension.setActionDelegate(actionDelegate)
        for (session in sessions.toList()) attachExtension(session, extension)
        rebuild()
    }

    /** Call for every public browser session before it is opened or first displayed. */
    fun attach(session: GeckoSession) {
        if (session.settings.usePrivateMode) return
        sessions += session
        for (extension in registered.values) attachExtension(session, extension)
    }
    fun detach(session: GeckoSession) {
        sessions -= session
        actions.keys.filter { it.session === session }.forEach(actions::remove)
        if (active === session) active = null
        rebuild()
    }
    fun activate(session: GeckoSession?) {
        active?.let { runtime.webExtensionController.setTabActive(it, false) }
        active = session?.takeUnless { it.settings.usePrivateMode }
        active?.let { attach(it); runtime.webExtensionController.setTabActive(it, true) }
        if (!canUse()) closePopup()
        rebuild()
    }

    fun click(rowId: String) {
        if (!canUse() || active == null) return
        val row = mutableRows.value.firstOrNull { it.id == rowId && it.enabled } ?: return
        val extension = registered[row.extensionId] ?: return
        if (!permitted(extension)) return
        resolved(extension.id, rowId.substringAfterLast(':'))?.click()
    }
    fun openOptions(id: String) {
        val extension = registered[id] ?: return
        if (!permitted(extension)) return
        val url = extension.metaData?.optionsPageUrl ?: return
        if (!ownExtensionUrl(extension, url)) return
        val session = makeSheet(extension, "${extension.metaData?.name ?: id} settings") ?: return
        session.loadUri(url)
    }
    fun openOptionsUrl(url: String): Boolean {
        val extension = registered.values.firstOrNull { it.metaData?.optionsPageUrl == url } ?: return false
        openOptions(extension.id)
        return mutablePopup.value != null
    }
    fun closePopup() {
        val session = mutablePopup.value
        mutablePopup.value = null; mutableTitle.value = ""; popupExtension = null
        session?.let { sessions -= it; if (it.isOpen) it.close() }
    }

    /** Call after manager refresh/remove/enable, so an old action cannot revive removed code. */
    fun reconcile(installedIds: Set<String>) {
        val removed = registered.keys.filter { it !in installedIds }
        for (id in removed) {
            registered.remove(id)?.let { it.setActionDelegate(null); it.setTabDelegate(null) }
            actions.keys.filter { it.id == id }.forEach(actions::remove)
            if (popupExtension == id) closePopup()
        }
        rebuild()
    }

    fun close() {
        closePopup()
        active?.let { runtime.webExtensionController.setTabActive(it, false) }
        active = null
        for (extension in registered.values) {
            extension.setActionDelegate(null); extension.setTabDelegate(null)
            sessions.forEach { session ->
                session.webExtensionController.setActionDelegate(extension, null)
                session.webExtensionController.setTabDelegate(extension, null)
            }
        }
        registered.clear(); sessions.clear(); actions.clear(); rebuild()
    }

    private fun attachExtension(session: GeckoSession, extension: WebExtension) {
        session.webExtensionController.setActionDelegate(extension, actionDelegate)
        session.webExtensionController.setTabDelegate(extension, object : WebExtension.SessionTabDelegate {
            override fun onCloseTab(source: WebExtension?, target: GeckoSession): GeckoResult<AllowOrDeny> {
                val allowed = source != null && permitted(source) && sessions.contains(target) && !target.settings.usePrivateMode && closeTab(target)
                if (allowed) detach(target)
                return GeckoResult.fromValue(if (allowed) AllowOrDeny.ALLOW else AllowOrDeny.DENY)
            }
            override fun onUpdateTab(source: WebExtension, target: GeckoSession, details: WebExtension.UpdateTabDetails): GeckoResult<AllowOrDeny> {
                // Native Gecko loads the URL after ALLOW. The callback only updates browser metadata.
                val allowed = permitted(source) && sessions.contains(target) && !target.settings.usePrivateMode && safeExtensionNavigation(source, details.url) && updateTab(target, details)
                return GeckoResult.fromValue(if (allowed) AllowOrDeny.ALLOW else AllowOrDeny.DENY)
            }
        })
    }

    private val actionDelegate = object : WebExtension.ActionDelegate {
        override fun onBrowserAction(extension: WebExtension, session: GeckoSession?, action: WebExtension.Action) { record(extension, session, "browser", action) }
        override fun onPageAction(extension: WebExtension, session: GeckoSession?, action: WebExtension.Action) { record(extension, session, "page", action) }
        override fun onTogglePopup(extension: WebExtension, action: WebExtension.Action): GeckoResult<GeckoSession>? {
            if (popupExtension == extension.id && mutablePopup.value != null) { closePopup(); return null }
            return onOpenPopup(extension, action)
        }
        override fun onOpenPopup(extension: WebExtension, action: WebExtension.Action): GeckoResult<GeckoSession>? {
            if (!permitted(extension)) return null
            val session = makeSheet(extension, action.title ?: extension.metaData?.name ?: extension.id) ?: return null
            return GeckoResult.fromValue(session)
        }
    }

    private fun record(extension: WebExtension, session: GeckoSession?, kind: String, action: WebExtension.Action) {
        if (registered[extension.id] !== extension || (session != null && (!sessions.contains(session) || session.settings.usePrivateMode))) return
        actions[Key(extension.id, kind, session)] = action
        rebuild()
    }
    private fun resolved(id: String, kind: String): WebExtension.Action? {
        val specific = actions[Key(id, kind, active)]
        val default = actions[Key(id, kind, null)]
        return if (specific != null && default != null) specific.withDefault(default) else specific ?: default
    }
    private fun rebuild() {
        mutableRows.value = if (!canUse() || active == null) emptyList() else registered.values.flatMap { extension ->
            if (!permitted(extension)) return@flatMap emptyList()
            listOf("browser", "page").mapNotNull { kind -> resolved(extension.id, kind)?.let { action ->
                if (kind == "page" && action.enabled != true) null
                else ExtensionActionRow("${extension.id}:$kind", extension.id, action.title ?: extension.metaData?.name ?: extension.id, action.badgeText.orEmpty(), action.enabled != false)
            } }
        }
    }
    private fun permitted(extension: WebExtension): Boolean = canUse() && registered[extension.id] === extension && extension.metaData?.enabled == true
    private fun makeSheet(extension: WebExtension, title: String, open: Boolean = true): GeckoSession? {
        if (!permitted(extension)) return null
        closePopup()
        val settings = GeckoSessionSettings.Builder().usePrivateMode(false).apply {
            val currentContext = active?.settings?.contextId
            if (currentContext != null) contextId(currentContext)
        }.build()
        val session = GeckoSession(settings)
        configureSheet(session)
        attach(session)
        if (open) session.open(runtime)
        popupExtension = extension.id; mutableTitle.value = title; mutablePopup.value = session
        return session
    }
    private fun safeExtensionNavigation(extension: WebExtension, url: String?): Boolean {
        if (url == null || url == "about:blank") return true
        return try { URI(url).scheme?.lowercase() in setOf("http", "https") || ownExtensionUrl(extension, url) } catch (_: Exception) { false }
    }
    private fun ownExtensionUrl(extension: WebExtension, url: String): Boolean {
        val baseUrl = extension.metaData?.baseUrl ?: return false
        return try {
            val base = URI(baseUrl)
            val destination = URI(url)
            destination.scheme == "moz-extension" && destination.host == base.host
        } catch (_: Exception) { false }
    }
}

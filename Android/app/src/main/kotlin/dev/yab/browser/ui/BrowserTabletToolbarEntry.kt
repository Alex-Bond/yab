package dev.yab.browser.ui

import dev.yab.browser.model.*

internal enum class BrowserTabletToolbarCommand { READER_BACK, HISTORY_BACK, OPENER_BACK, FORWARD, RELOAD, STOP, ALL_TABS }

/** One render's actual public PAGE. Commands never choose today's target or role on click. */
class BrowserTabletToolbarEntry private constructor(
    private val controller: BrowserController,
    private val engine: BrowserEngine,
    private val page: BrowserTabletSidebarEntry,
    private val original: BrowserState,
    private val revision: Long,
    private val originalSite: PageMenuLease?,
    private val originalSiteCurrent: (PageMenuLease) -> Boolean,
    private val retainedContextCurrent: () -> Boolean,
) {
    private var retired = false
    private val tab = original.tab
    private val opener = tab?.openerId?.takeUnless { it == tab.id }?.let { id ->
        original.space?.tabs?.singleOrNull { it.id == id && !it.isPrivate }
    }
    internal val back: BrowserTabletToolbarCommand? = when {
        tab == null -> null
        original.page.readerEnabled -> BrowserTabletToolbarCommand.READER_BACK
        original.page.canGoBack -> BrowserTabletToolbarCommand.HISTORY_BACK
        opener != null -> BrowserTabletToolbarCommand.OPENER_BACK
        else -> null
    }
    internal val reload: BrowserTabletToolbarCommand? = tab?.let {
        if (original.page.loading) BrowserTabletToolbarCommand.STOP else BrowserTabletToolbarCommand.RELOAD
    }
    internal val forwardAvailable = tab != null && original.page.canGoForward
    // Phone TabRecency.order explicitly includes the real front, including blank.
    // Genuine Empty has no front and must not manufacture a Gallery card.
    internal val galleryAvailable = tab != null
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!page.current()) { retired = true; return false }
        return true
    }
    private fun factsCurrent(): Boolean = controller.tabletToolbarRevision.value == revision &&
        controller.state.value.let { now ->
            now.page.loading == original.page.loading && now.page.readerEnabled == original.page.readerEnabled &&
                now.page.canGoBack == original.page.canGoBack && now.page.canGoForward == original.page.canGoForward &&
                (opener == null || now.space?.tabs?.singleOrNull { it.id == opener.id } == opener)
        }
    internal fun command(kind: BrowserTabletToolbarCommand): BrowserTabletSidebarAction? {
        val permitted = when (kind) {
            BrowserTabletToolbarCommand.READER_BACK, BrowserTabletToolbarCommand.HISTORY_BACK,
            BrowserTabletToolbarCommand.OPENER_BACK -> kind == back
            BrowserTabletToolbarCommand.FORWARD -> forwardAvailable
            BrowserTabletToolbarCommand.RELOAD, BrowserTabletToolbarCommand.STOP -> kind == reload
            BrowserTabletToolbarCommand.ALL_TABS -> galleryAvailable
        }
        if (!permitted || !current()) return null
        val typed = kind != BrowserTabletToolbarCommand.ALL_TABS
        return BrowserTabletSidebarAction({ current() && (!typed || factsCurrent()) && current() && (!typed || factsCurrent()) }) {
            when (kind) {
                BrowserTabletToolbarCommand.READER_BACK -> tab?.let { engine.setReader(it.id, false) } == true
                BrowserTabletToolbarCommand.HISTORY_BACK -> { engine.goBack(checkNotNull(tab).id); true }
                BrowserTabletToolbarCommand.OPENER_BACK -> controller.back()
                BrowserTabletToolbarCommand.FORWARD -> { engine.goForward(checkNotNull(tab).id); true }
                BrowserTabletToolbarCommand.RELOAD -> { engine.reload(checkNotNull(tab).id); true }
                BrowserTabletToolbarCommand.STOP -> { engine.stop(checkNotNull(tab).id); true }
                BrowserTabletToolbarCommand.ALL_TABS -> { controller.show(BrowserSurface.GALLERY); true }
            }
        }
    }
    internal fun newTab(): BrowserTabletSidebarAction? = if (current()) page.newTab() else null
    internal fun site(): BrowserTabletSiteSource? = originalSite?.takeIf { current() && originalSiteCurrent(it) }
        ?.let { BrowserTabletSiteSource(it, ::current, originalSiteCurrent) }
    internal fun gallery(originalAction: BrowserTabletSidebarAction): BrowserTabletGallerySource? = if (galleryAvailable && current())
        BrowserTabletGallerySource(controller, original, originalAction, retainedContextCurrent) else null

    companion object {
        /** Only a fresh render can capture. These getters do not acquire a native owner,
         * and the final snapshot/revision check brackets the external source predicate. */
        internal fun capture(controller: BrowserController, engine: BrowserEngine, page: BrowserTabletSidebarEntry,
            rendered: BrowserState, revision: Long, site: PageMenuLease?,
            retainedContextCurrent: () -> Boolean, siteCurrent: (PageMenuLease) -> Boolean): BrowserTabletToolbarEntry? {
            fun unchanged() = controller.state.value === rendered && controller.tabletToolbarRevision.value == revision
            if (!unchanged() || !page.current() || !unchanged()) return null
            return BrowserTabletToolbarEntry(controller, engine, page, rendered, revision, site, siteCurrent, retainedContextCurrent)
        }
    }
}

/** The actual public blank front of one original Gallery render. The toolbar opener
 * retains its original source; a replacement Activity must capture a fresh Gallery
 * context during render. Neither path can restore a PAGE action. */
class BrowserTabletGallerySource private constructor(private val controller: BrowserController,
    private val original: BrowserState, private val originalAction: BrowserTabletSidebarAction?,
    private val originalContextCurrent: () -> Boolean, private val capturedGallery: Boolean,
    private val lifetime: SettingsPresentationLifetime, private val window: WorkspaceWindowState,
    private val generation: Long) {
    internal constructor(controller: BrowserController, original: BrowserState,
        originalAction: BrowserTabletSidebarAction, originalContextCurrent: () -> Boolean) : this(
        controller, original, originalAction, originalContextCurrent, false,
        controller.settingsPresentationLifetime.value, controller.workspaceWindow.value,
        controller.historyPresentationLifetime.value)
    private val front = checkNotNull(original.tab)
    private val profile = original.space?.websiteProfile
    private var opened = capturedGallery
    private var attempted = capturedGallery
    private var retired = false
    internal fun retire() { retired = true }
    internal fun open(): Boolean {
        if (attempted || retired) return false
        attempted = true
        if (!originalContextCurrent() || originalAction?.perform() != true) { retired = true; return false }
        opened = true
        return current()
    }
    private fun matches(now: BrowserState): Boolean = opened && !now.loading && !now.privateContentBlocked &&
        now.surface == BrowserSurface.GALLERY && now.surfaceEpoch == original.surfaceEpoch + (if (capturedGallery) 0 else 1) &&
        now.selectedSpaceId == original.selectedSpaceId && now.space?.isPrivate == false &&
        now.space?.websiteProfile == profile && now.tab?.let {
            it.id == front.id && it.url == front.url && !it.isPrivate
        } == true && now.space?.tabs?.singleOrNull { it.id == front.id } == now.tab &&
        controller.settingsPresentationLifetime.value == lifetime && lifetime.active &&
        controller.workspaceWindow.value == window && controller.historyPresentationLifetime.value == generation + (if (capturedGallery) 0 else 1)
    internal fun current(): Boolean {
        if (retired || !opened) return false
        if (!matches(controller.state.value) || !originalContextCurrent() || !matches(controller.state.value)) {
            retired = true; return false
        }
        return true
    }
    internal fun cards(rendered: BrowserState): List<BrowserTab> {
        val ordinary = rendered.privateFrontGalleryCards()
        if (!front.isBlank || !current() || controller.state.value !== rendered) return ordinary
        val actual = rendered.tab ?: return ordinary
        return if (actual.isBlank && ordinary.none { it.id == actual.id }) listOf(actual) + ordinary else ordinary
    }
    /** The current blank is already selected. Only this original toolbar result
     * may return to it among other cards; ordinary/private filtering is unchanged. */
    internal fun ownsBlankFront(page: BrowserTab, selectedProfile: WebsiteProfile): Boolean =
        page.isBlank && !page.isPrivate && page.id == front.id && page.url == front.url &&
            selectedProfile == profile && current() && controller.state.value.tab == page && current()

    companion object {
        /** A new rendered Gallery owns only its actual blank front. It cannot reopen
         * a PAGE action, and no old callback may invoke this capture factory. */
        internal fun captureGallery(controller: BrowserController, rendered: BrowserState,
            originalContextCurrent: () -> Boolean): BrowserTabletGallerySource? {
            val front = rendered.tab ?: return null
            val space = rendered.space ?: return null
            val lifetime = controller.settingsPresentationLifetime.value
            val window = controller.workspaceWindow.value
            val generation = controller.historyPresentationLifetime.value
            fun unchanged() = controller.state.value === rendered &&
                controller.settingsPresentationLifetime.value == lifetime &&
                controller.workspaceWindow.value == window && controller.historyPresentationLifetime.value == generation
            if (rendered.loading || rendered.privateContentBlocked || rendered.surface != BrowserSurface.GALLERY ||
                space.isPrivate || front.isPrivate || !front.isBlank ||
                space.tabs.singleOrNull { it.id == front.id } != front || !lifetime.active ||
                !window.registered || window.geometry?.valid != true || !unchanged() ||
                !originalContextCurrent() || !unchanged()) return null
            return BrowserTabletGallerySource(controller, rendered, null, originalContextCurrent, true,
                lifetime, window, generation)
        }
    }
}

/** Generation binding is bookkeeping on one captured native lease, never fresh source capture.
 * Once admitted, the owned menu uses its separate retained source check through its own cover. */
internal class BrowserTabletSiteSource(private val original: PageMenuLease,
    private val admission: () -> Boolean, private val originalCurrent: (PageMenuLease) -> Boolean) {
    private var consumed = false
    private var retired = false
    private var bound: PageMenuLease? = null
    fun bind(generation: Long): PageMenuLease? {
        if (consumed || retired) return null
        if (generation <= 0 || !admission() || !originalCurrent(original)) { retired = true; return null }
        consumed = true
        return original.copy(generation = generation).also { bound = it }
    }
    fun current(lease: PageMenuLease): Boolean {
        if (retired || bound !== lease) return false
        if (!originalCurrent(lease)) { retired = true; return false }
        return true
    }
}

/** Actual Screen node/layout ownership is additive to the original Main PAGE environment. */
internal class BrowserTabletToolbarControl(private val original: BrowserTabletToolbarEntry,
    private val originalSceneCurrent: () -> Boolean) {
    private var retired = false
    val back get() = original.back
    val reload get() = original.reload
    val forwardAvailable get() = original.forwardAvailable
    val galleryAvailable get() = original.galleryAvailable
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!originalSceneCurrent() || !original.current() || !originalSceneCurrent()) { retired = true; return false }
        return true
    }
    fun command(kind: BrowserTabletToolbarCommand): BrowserTabletSidebarAction? =
        if (current()) scoped(original.command(kind)) else null
    fun newTab(): BrowserTabletSidebarAction? = if (current()) scoped(original.newTab()) else null
    fun site(): BrowserTabletSiteSource? = if (current()) original.site() else null
    fun gallery(): BrowserTabletGallerySource? = if (current()) command(BrowserTabletToolbarCommand.ALL_TABS)
        ?.let { original.gallery(it) } else null
    private fun scoped(action: BrowserTabletSidebarAction?): BrowserTabletSidebarAction? = action?.let {
        BrowserTabletSidebarAction({ current() && it.current() }, it::perform)
    }
}

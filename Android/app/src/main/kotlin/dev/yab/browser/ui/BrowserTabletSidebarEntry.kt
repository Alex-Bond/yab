package dev.yab.browser.ui

import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserFolder
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.TabletSidebarActionLease
import dev.yab.browser.model.TabletSidebarPageLease

/** The originally captured Activity/account/native context. A failed original check
 * stays refused; neither a command nor this object may capture replacement authority. */
internal class BrowserTabletPageEnvironment(private val originalCurrent: () -> Boolean) {
    private var retired = false
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!originalCurrent()) { retired = true; return false }
        return true
    }
}

/** Captured during a fresh public PAGE render. Actual UI controls must also retain
 * their original layout/scene scope; this preparation adds no sidebar UI. */
class BrowserTabletSidebarEntry internal constructor(
    private val controller: BrowserController,
    private val original: TabletSidebarPageLease,
    private val environment: BrowserTabletPageEnvironment,
) {
    private var retired = false
    val space: BrowserSpace get() = original.space
    val spaces: List<BrowserSpace> = controller.state.value.spaces.filterNot { it.isPrivate }.toList()
    val pair: List<BrowserTab> = original.workspace?.let { pair ->
        listOf(pair.first, pair.second).mapNotNull { id -> original.space.tabs.singleOrNull { it.id == id && !it.isPrivate } }
    }?.takeIf { it.size == 2 }.orEmpty()
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!controller.tabletSidebarPageCurrent(original) || !environment.current() ||
            !controller.tabletSidebarPageCurrent(original)) { retired = true; return false }
        return true
    }

    /** Capture the actual original rendered target, never a new target on an old click. */
    fun tab(tab: BrowserTab): BrowserTabletSidebarAction? = if (!current()) null else
        controller.captureTabletSidebarTab(original, tab)?.let { action ->
            command(action) { controller.selectTabletSidebarTab(action) }
        }
    fun folder(folder: BrowserFolder): BrowserTabletSidebarAction? = if (!current()) null else
        controller.captureTabletSidebarFolder(original, folder)?.let { action ->
            command(action) { controller.toggleTabletSidebarFolder(action) }
        }
    fun clearToday(): BrowserTabletSidebarAction? = if (!current()) null else
        controller.captureTabletSidebarClearToday(original)?.let { action ->
            command(action) { controller.clearTabletSidebarToday(action) }
        }
    fun newTab(): BrowserTabletSidebarAction? = if (!current()) null else
        controller.captureTabletSidebarNewTab(original)?.let { action ->
            command(action) { controller.newTabletSidebarTab(action) }
        }

    fun space(target: BrowserSpace): BrowserTabletSidebarAction? {
        fun admitted() = current() && !target.isPrivate && spaces.singleOrNull { it.id == target.id } == target &&
            controller.state.value.spaces.singleOrNull { it.id == target.id } == target
        return if (!admitted()) null else BrowserTabletSidebarAction(::admitted) {
            if (!admitted()) false else { controller.selectSpace(target.id); true }
        }
    }

    fun settings(): BrowserTabletSidebarAction? = if (!current()) null else
        BrowserTabletSidebarAction(::current) {
            if (!current()) false else { controller.show(dev.yab.browser.model.BrowserSurface.SETTINGS); true }
        }

    private fun command(action: TabletSidebarActionLease, perform: () -> Boolean) =
        BrowserTabletSidebarAction({ current() && controller.tabletSidebarActionCurrent(action) }, perform)
}

/** UI80 supplies its original layout/scene predicate and captures these actions during
 * render. An old control never captures a replacement entry, row or layout at click. */
internal class BrowserTabletSidebarControl(private val entry: BrowserTabletSidebarEntry,
    private val originalSceneCurrent: () -> Boolean) {
    private var retired = false
    val space: BrowserSpace get() = entry.space
    val spaces: List<BrowserSpace> get() = entry.spaces
    val pair: List<BrowserTab> get() = entry.pair
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!originalSceneCurrent() || !entry.current()) { retired = true; return false }
        return true
    }
    fun tab(tab: BrowserTab): BrowserTabletSidebarAction? = if (!current()) null else scoped(entry.tab(tab))
    fun folder(folder: BrowserFolder): BrowserTabletSidebarAction? = if (!current()) null else scoped(entry.folder(folder))
    fun clearToday(): BrowserTabletSidebarAction? = if (!current()) null else scoped(entry.clearToday())
    fun newTab(): BrowserTabletSidebarAction? = if (!current()) null else scoped(entry.newTab())
    fun settings(): BrowserTabletSidebarAction? = if (!current()) null else scoped(entry.settings())
    fun space(target: BrowserSpace): BrowserTabletSidebarAction? = if (!current()) null else scoped(entry.space(target))
    private fun scoped(original: BrowserTabletSidebarAction?): BrowserTabletSidebarAction? = original?.let {
        BrowserTabletSidebarAction({ current() && it.current() }, it::perform)
    }
}

/** One actual command. Retire/key the rendered control separately on layout changes. */
class BrowserTabletSidebarAction internal constructor(
    private val originalCurrent: () -> Boolean,
    private val originalPerform: () -> Boolean,
) {
    private var retired = false
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!originalCurrent()) { retired = true; return false }
        return true
    }
    fun perform(): Boolean {
        if (!current()) return false
        // Consume before the existing synchronous Controller/engine call can reenter.
        retired = true
        return originalPerform()
    }
}

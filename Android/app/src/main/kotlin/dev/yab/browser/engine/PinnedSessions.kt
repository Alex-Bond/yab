package dev.yab.browser.engine

import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.TabPlace

/** Pins of the space on screen stay awake (docs/hidden-tabs.md, feedback 745): coming back to
 * one is never a reload, however many other pages were opened since. Only memory pressure lets
 * an unused pin go. A pin of another space sleeps as any tab does. */
internal class PinnedSessions(private val spaces: Map<String, String> = emptyMap(), private val pins: Set<String> = emptySet()) {
    fun holds(tab: String, selected: String?, memoryPressure: Boolean): Boolean =
        !memoryPressure && tab in pins && selected != null && spaces[tab] == spaces[selected]

    companion object {
        fun of(all: List<BrowserSpace>) = PinnedSessions(
            all.flatMap { space -> space.tabs.map { it.id to space.id } }.toMap(),
            all.flatMap { space -> space.tabs.filter { it.place == TabPlace.PINNED }.map { it.id } }.toSet())
    }
}

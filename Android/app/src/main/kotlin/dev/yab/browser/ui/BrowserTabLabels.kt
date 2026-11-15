package dev.yab.browser.ui

import dev.yab.browser.model.BrowserTab

/** Compact local page names follow Phone Tab.short. Synced titles can already
 * contain a person's custom Mac label, so their text stays intact. */
internal val BrowserTab.shortTitle: String get() = if (shared) title else title.substringBefore(" · ")

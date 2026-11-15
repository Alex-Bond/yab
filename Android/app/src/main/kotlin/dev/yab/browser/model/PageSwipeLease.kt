package dev.yab.browser.model

/** One process-local page/space/account/background generation and its exact neighbors.
 * Constructed only by BrowserController; the visible preview cannot authorize selection. */
class PageSwipeLease internal constructor(internal val ownership: Long, internal val generation: Long,
    internal val epoch: Long, internal val space: String, val profile: WebsiteProfile,
    val front: BrowserTab, val before: BrowserTab?, val after: BrowserTab?)

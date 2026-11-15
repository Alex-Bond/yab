package dev.yab.browser.model

/** One blocked Private page's RAM-only authentication attempt. Equality is object identity. */
class PrivateUnlockLease internal constructor(internal val ownership: Long, internal val epoch: Long,
    internal val space: String, internal val profile: WebsiteProfile, internal val tab: String?, internal val url: String?)

package dev.yab.browser.model

enum class HistorySwipeDirection { BACK, FORWARD }

/** Created by the engine from one copied native history revision, never from a URL. */
class NativeHistorySwipeTarget internal constructor(internal val token: String, val direction: HistorySwipeDirection)

/** Process-local user/space/page/setting lifetime. Not serializable or a preview authority. */
class HistorySwipeLease internal constructor(internal val ownership: Long, internal val background: Long,
    internal val setting: Long, internal val epoch: Long, internal val space: String,
    internal val workspace: BrowserWorkspace?, val profile: WebsiteProfile, val front: BrowserTab,
    val direction: HistorySwipeDirection, internal val target: NativeHistorySwipeTarget?,
    internal val opener: BrowserTab?)

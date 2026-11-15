package dev.yab.browser.engine

/** Created only by Gecko's native long-press callback. No script can submit this request. */
data class PageContextMenu(
    val id: String,
    val tab: String,
    val profile: String,
    val isPrivate: Boolean,
    val link: String?,
    val image: String?,
    val title: String,
)

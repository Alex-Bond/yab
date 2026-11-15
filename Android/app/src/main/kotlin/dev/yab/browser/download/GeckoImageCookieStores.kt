package dev.yab.browser.download

/** Pinned GeckoView uses distinct tab and webRequest labels for its session-context namespace.
 * The actual namespace remains the captured native GeckoSession.settings.contextId.
 */
internal object GeckoImageCookieStores {
    private const val PREFIX = "firefox-container-"
    fun tab(context: String, privately: Boolean): String? {
        if (context.isBlank() || context.length > 256 - PREFIX.length) return null
        return if (privately) "firefox-private" else PREFIX + context
    }
    fun request(privately: Boolean) = if (privately) "firefox-private" else "firefox-default"
}

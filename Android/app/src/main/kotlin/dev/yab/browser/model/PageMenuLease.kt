package dev.yab.browser.model

/** Process-local provenance, never persisted or synced. The native owner is an opaque captured
 * document/session capability; IDs and a URL alone cannot authorize a menu operation. The caller
 * must compare it with the live engine and one atomic account snapshot on every current() call. */
data class PageMenuLease internal constructor(
    val account: String?,
    val accountEpoch: Long,
    val tab: String,
    val space: String,
    val profile: WebsiteProfile,
    val nativeOwner: Any,
    val surfaceEpoch: Long,
    val generation: Long,
    val device: String? = null,
    val entrance: Long = 0,
    val url: String? = null,
    val windowGeneration: Long = 0,
)

/** Local browser facts are checked separately from the caller's atomic account/native proof. */
internal fun PageMenuLease.ownsSource(state: BrowserState, originalUrl: String): Boolean =
    !state.loading && !state.privateContentBlocked && state.find == null && state.surface == BrowserSurface.PAGE &&
        state.surfaceEpoch == surfaceEpoch && state.selectedSpaceId == space && state.space?.websiteProfile == profile &&
        (url == null || url == originalUrl) && state.tab?.let { it.id == tab && it.url == originalUrl &&
            (it.isPrivate || state.space?.isPrivate == true) == profile.isPrivate } == true

/** Drawing only: the immediately succeeding address Field can finish the outgoing sheet.
 * This never admits a menu action. The caller separately checks fieldInputCurrent plus the
 * original atomic account/native/window owner on every projection and draw. */
internal fun PageMenuLease.ownsDrawnField(state: BrowserState, input: FieldInputLease, originalUrl: String): Boolean =
    !state.loading && !state.privateContentBlocked && state.find == null && state.surface == BrowserSurface.FIELD &&
        !state.fieldIsNewTab && input.surface == BrowserSurface.FIELD && !input.newTab &&
        input.epoch == surfaceEpoch + 1 && state.surfaceEpoch == input.epoch &&
        input.space == space && input.profile == profile && input.tab == tab && input.url == originalUrl &&
        input.privately == profile.isPrivate && state.fieldIsPrivate == profile.isPrivate &&
        state.selectedSpaceId == space && state.space?.websiteProfile == profile &&
        state.fieldOriginTab == tab && state.fieldOriginSpace == space && state.fieldOriginProfile == profile &&
        (url == null || url == originalUrl) && state.tab?.let { it.id == tab && it.url == originalUrl &&
            (it.isPrivate || state.space?.isPrivate == true) == profile.isPrivate } == true

package dev.yab.browser.media

/** These identities and all private playback state live only in this process. */
data class MediaOwner(val tabId: String, val document: String, val session: String, val privateOrigin: Boolean)
enum class MediaAction { PLAY, PAUSE, STOP, SEEK_TO, SEEK_FORWARD, SEEK_BACKWARD, NEXT, PREVIOUS }
data class MediaCommand(val action: MediaAction, val positionSeconds: Double? = null)
data class PageMediaState(
    val owner: MediaOwner,
    val active: Boolean = true,
    val playing: Boolean = false,
    val title: String = "",
    val artist: String = "",
    val album: String = "",
    val actions: Set<MediaAction> = emptySet(),
    val positionSeconds: Double = 0.0,
    val durationSeconds: Double = 0.0,
    val playbackRate: Double = 1.0,
    val positionAtElapsed: Long = 0,
    val playedAtElapsed: Long = 0,
    val fullscreen: Boolean = false,
    val videoWidth: Long = 0,
    val videoHeight: Long = 0,
    val hasVideo: Boolean = false,
) {
    fun mayExport(lockPrivate: Boolean): Boolean = active && (!owner.privateOrigin || !lockPrivate)
    fun systemMetadata(): PageMediaState = if (owner.privateOrigin) copy(title = "Private media", artist = "", album = "")
        else copy(title = title.filterNot(Char::isISOControl).take(200), artist = artist.filterNot(Char::isISOControl).take(200), album = album.filterNot(Char::isISOControl).take(200))
}

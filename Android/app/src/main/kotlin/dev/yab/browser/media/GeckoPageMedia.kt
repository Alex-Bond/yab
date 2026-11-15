package dev.yab.browser.media

import android.os.SystemClock
import dev.yab.browser.model.WebsiteProfile
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.MediaSession

/** Native Gecko events establish playback; page script reports cannot impersonate them. */
class GeckoPageMedia(private val changed: (String, Boolean) -> Unit) {
    private data class Live(val session: GeckoSession, val media: MediaSession, val current: () -> Boolean,
                            val document: () -> String, var state: PageMediaState)
    private val live = linkedMapOf<String, Live>()
    private val mutable = MutableStateFlow<List<PageMediaState>>(emptyList())
    val state: StateFlow<List<PageMediaState>> = mutable

    fun delegate(id: String, session: GeckoSession, profile: WebsiteProfile, document: () -> String,
                 current: () -> Boolean): MediaSession.Delegate {
        val sessionIdentity = UUID.randomUUID().toString()
        var nativeFeatures: Pair<String, Long>? = null
        fun actions(features: Long): Set<MediaAction> = buildSet {
            fun addIf(bit: Long, action: MediaAction) { if (features and bit != 0L) add(action) }
            addIf(MediaSession.Feature.PLAY, MediaAction.PLAY); addIf(MediaSession.Feature.PAUSE, MediaAction.PAUSE)
            addIf(MediaSession.Feature.STOP, MediaAction.STOP); addIf(MediaSession.Feature.SEEK_TO, MediaAction.SEEK_TO)
            addIf(MediaSession.Feature.SEEK_FORWARD, MediaAction.SEEK_FORWARD); addIf(MediaSession.Feature.SEEK_BACKWARD, MediaAction.SEEK_BACKWARD)
            addIf(MediaSession.Feature.NEXT_TRACK, MediaAction.NEXT); addIf(MediaSession.Feature.PREVIOUS_TRACK, MediaAction.PREVIOUS)
        }
        fun entry(media: MediaSession): Live? = live[id]?.takeIf {
            current() && it.session === session && it.media === media && it.state.owner.document == document()
        }
        fun update(media: MediaSession, transform: (PageMediaState) -> PageMediaState) {
            val item = entry(media) ?: return
            item.state = transform(item.state); publish(); changed(id, item.state.playing)
        }
        return object : MediaSession.Delegate {
            override fun onActivated(s: GeckoSession, media: MediaSession) {
                if (!current() || s !== session) return
                val owner = MediaOwner(id, document(), sessionIdentity, profile.isPrivate)
                // Gecko 158's native MediaController starts with these six supported
                // transport keys, but GeckoView only publishes Features on a later
                // supportedkeyschange. Activation itself does not send that snapshot.
                // Match dom/media/mediacontrol/MediaController.cpp at FIREFOX_158_0_RELEASE;
                // never infer NEXT/PREVIOUS, playback, or ownership from page script.
                val initial = nativeFeatures?.takeIf { it.first == owner.document }?.let { actions(it.second) }
                    ?: setOf(MediaAction.PLAY, MediaAction.PAUSE, MediaAction.STOP, MediaAction.SEEK_TO,
                        MediaAction.SEEK_FORWARD, MediaAction.SEEK_BACKWARD)
                live[id] = Live(session, media, current, document, PageMediaState(owner, actions = initial))
                publish()
            }
            override fun onDeactivated(s: GeckoSession, media: MediaSession) {
                if (entry(media) != null) { nativeFeatures = null; forget(id) }
            }
            override fun onPlay(s: GeckoSession, media: MediaSession) = update(media) {
                it.copy(playing = true, playedAtElapsed = SystemClock.elapsedRealtime())
            }
            override fun onPause(s: GeckoSession, media: MediaSession) = update(media) { it.copy(playing = false) }
            override fun onStop(s: GeckoSession, media: MediaSession) = update(media) { it.copy(playing = false) }
            override fun onMetadata(s: GeckoSession, media: MediaSession, meta: MediaSession.Metadata) = update(media) {
                it.copy(title = meta.title.orEmpty(), artist = meta.artist.orEmpty(), album = meta.album.orEmpty())
            }
            override fun onFeatures(s: GeckoSession, media: MediaSession, features: Long) {
                if (!current() || s !== session) return
                nativeFeatures = document() to features
                update(media) { it.copy(actions = actions(features)) }
            }
            override fun onPositionState(s: GeckoSession, media: MediaSession, position: MediaSession.PositionState) = update(media) {
                it.copy(positionSeconds = position.position.takeIf(Double::isFinite)?.coerceAtLeast(0.0) ?: 0.0,
                    durationSeconds = position.duration.takeIf(Double::isFinite)?.coerceAtLeast(0.0) ?: 0.0,
                    playbackRate = position.playbackRate.takeIf(Double::isFinite) ?: 1.0,
                    positionAtElapsed = SystemClock.elapsedRealtime())
            }
            override fun onFullscreen(s: GeckoSession, media: MediaSession, enabled: Boolean, meta: MediaSession.ElementMetadata?) = update(media) {
                it.copy(fullscreen = enabled, hasVideo = enabled && (meta?.videoTrackCount ?: 0) > 0,
                    videoWidth = meta?.width ?: 0, videoHeight = meta?.height ?: 0)
            }
        }
    }
    private fun publish() { mutable.value = live.values.map { it.state } }
    fun playing(id: String): Boolean = live[id]?.state?.playing == true
    fun forget(id: String) { live.remove(id)?.let { changed(id, false) }; publish() }
    fun close() { live.keys.toList().forEach(::forget) }
    fun command(owner: MediaOwner, command: MediaCommand, allowed: (MediaOwner) -> Boolean): Boolean {
        val item = live[owner.tabId]?.takeIf { it.state.owner == owner && it.current() && it.document() == owner.document && it.media.isActive && allowed(owner) } ?: return false
        if (command.action !in item.state.actions) return false
        when (command.action) {
            MediaAction.PLAY -> item.media.play()
            MediaAction.PAUSE -> item.media.pause()
            MediaAction.STOP -> item.media.stop()
            MediaAction.SEEK_FORWARD -> item.media.seekForward()
            MediaAction.SEEK_BACKWARD -> item.media.seekBackward()
            MediaAction.NEXT -> item.media.nextTrack()
            MediaAction.PREVIOUS -> item.media.previousTrack()
            MediaAction.SEEK_TO -> {
                val position = command.positionSeconds?.takeIf { it.isFinite() && it >= 0 } ?: return false
                if (item.state.durationSeconds > 0 && position > item.state.durationSeconds) return false
                item.media.seekTo(position, false)
            }
        }
        return true
    }
    fun focusChange(change: Int, allowed: (MediaOwner) -> Boolean) {
        live.values.filter { it.current() && it.document() == it.state.owner.document && allowed(it.state.owner) }
            .forEach { it.media.notifySystemAudioFocusChange(change) }
    }
    fun pausePrivate() {
        live.values.filter { it.state.owner.privateOrigin && it.current() }.forEach {
            it.media.notifySystemAudioFocusChange(MediaSession.SYSTEM_AUDIO_FOCUS_PERMANENT_LOSS)
            it.media.pause(); it.state = it.state.copy(playing = false, fullscreen = false)
            changed(it.state.owner.tabId, false)
        }
        publish()
    }
}

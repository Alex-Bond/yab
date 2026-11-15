package dev.yab.browser.media

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import dev.yab.android.MainActivity
import dev.yab.android.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.combine

/** Hosts the system session and the notification for an existing live Gecko player. */
class PageMediaService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var controller: PageMediaController? = null
    private var observer: Job? = null
    private var session: MediaSession? = null
    private var foreground = false
    private var current: PageMediaState? = null
    private var pendingPlayUntil = 0L
    private val handler = Handler(Looper.getMainLooper())
    private val notifications get() = getSystemService(NotificationManager::class.java)

    override fun onCreate() {
        super.onCreate()
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "Page playback", NotificationManager.IMPORTANCE_LOW))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val next = PageMediaRegistry.get(intent?.getStringExtra(CONTROLLER))
        val state = next?.state?.value
        if (next == null || state == null) { stopSelf(startId); return START_NOT_STICKY }
        val requested = command(intent)
        if (requested != null && requested.first == state.owner && requested.second.action == MediaAction.PLAY) {
            pendingPlayUntil = SystemClock.elapsedRealtime() + 5000
            handler.postDelayed({ current?.takeIf { !it.playing }?.let { pendingPlayUntil = 0; publish(it) } }, 5000)
        }
        if (controller !== next) {
            observer?.cancel(); releaseSession()
            controller = next
            session = MediaSession(this, "Yab page playback").also { platform ->
                platform.setCallback(object : MediaSession.Callback() {
                    private fun send(command: MediaCommand) { current?.let { controller?.transport(it.owner, command) } }
                    override fun onPlay() = send(MediaCommand(MediaAction.PLAY))
                    override fun onPause() = send(MediaCommand(MediaAction.PAUSE))
                    override fun onStop() = send(MediaCommand(MediaAction.STOP))
                    override fun onSeekTo(pos: Long) = send(MediaCommand(MediaAction.SEEK_TO, pos / 1000.0))
                    override fun onSkipToNext() = send(MediaCommand(MediaAction.NEXT))
                    override fun onSkipToPrevious() = send(MediaCommand(MediaAction.PREVIOUS))
                    override fun onFastForward() = send(MediaCommand(MediaAction.SEEK_FORWARD))
                    override fun onRewind() = send(MediaCommand(MediaAction.SEEK_BACKWARD))
                }, Handler(Looper.getMainLooper()))
                platform.setSessionActivity(openActivity())
                platform.isActive = true
            }
            observer = scope.launch { combine(next.state, next.interruptedPlayback) { value, _ -> value }.collect { value ->
                if (value == null) { stopForeground(STOP_FOREGROUND_REMOVE); foreground = false; next.foregroundService(false); stopSelf() }
                else publish(value)
            } }
        }
        // A direct user transport action can restart foreground playback from a
        // paused media session. Enter foreground before dispatching to Gecko.
        current = state
        if (!enterForeground(notification(state))) return START_NOT_STICKY
        foreground = true; next.foregroundService(true)
        requested?.let { (owner, action) ->
            if (!next.deliver(owner, action)) { pendingPlayUntil = 0; publish(next.state.value ?: state) }
        }
        publish(next.state.value ?: state)
        return START_NOT_STICKY
    }

    private fun publish(value: PageMediaState) {
        val platform = session ?: return
        current = value
        if (value.playing) pendingPlayUntil = 0
        val resuming = SystemClock.elapsedRealtime() < pendingPlayUntil
        val actions = value.actions.fold(0L) { bits, action -> bits or action.platformAction() }
        platform.setMetadata(MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, value.title.ifBlank { "Yab media" })
            .putString(MediaMetadata.METADATA_KEY_ARTIST, value.artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, value.album)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, milliseconds(value.durationSeconds)).build())
        platform.setPlaybackState(PlaybackState.Builder().setActions(actions)
            .setState(if (value.playing) PlaybackState.STATE_PLAYING else if (resuming) PlaybackState.STATE_BUFFERING else PlaybackState.STATE_PAUSED,
                milliseconds(value.positionSeconds), value.playbackRate.coerceIn(-16.0, 16.0).toFloat(), value.positionAtElapsed.takeIf { it > 0 } ?: SystemClock.elapsedRealtime()).build())
        val notification = notification(value)
        if (value.playing || resuming || controller?.interruptedPlayback?.value == true) {
            if (!enterForeground(notification)) return
            foreground = true; controller?.foregroundService(true)
        } else {
            if (foreground) stopForeground(STOP_FOREGROUND_DETACH)
            foreground = false; controller?.foregroundService(false)
            notifications.notify(NOTIFICATION_ID, notification)
        }
    }

    private fun enterForeground(notification: Notification): Boolean = try {
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        true
    } catch (_: RuntimeException) {
        pendingPlayUntil = 0; controller?.serviceFailed(); stopSelf()
        false
    }

    private fun notification(value: PageMediaState): Notification {
        val builder = Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_yab)
            .setContentTitle(value.title.ifBlank { "Yab media" }).setContentText(value.artist)
            .setContentIntent(openActivity()).setOnlyAlertOnce(true)
            .setVisibility(if (value.owner.privateOrigin) Notification.VISIBILITY_PRIVATE else Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT).setOngoing(value.playing)
        val ordered = listOf(MediaAction.PREVIOUS, if (value.playing) MediaAction.PAUSE else MediaAction.PLAY, MediaAction.NEXT)
        var count = 0
        for (action in ordered.filter { it in value.actions }) {
            val icon = when (action) {
                MediaAction.PLAY -> android.R.drawable.ic_media_play
                MediaAction.PAUSE -> android.R.drawable.ic_media_pause
                MediaAction.NEXT -> android.R.drawable.ic_media_next
                else -> android.R.drawable.ic_media_previous
            }
            builder.addAction(Notification.Action.Builder(icon, action.name.lowercase().replaceFirstChar(Char::uppercase), pending(value.owner, MediaCommand(action))).build())
            count++
        }
        val style = Notification.MediaStyle().setMediaSession(requireNotNull(session).sessionToken)
        if (count > 0) style.setShowActionsInCompactView(*IntArray(count) { it })
        return builder.setStyle(style).build()
    }

    private fun pending(owner: MediaOwner, command: MediaCommand): PendingIntent {
        val controllerId = requireNotNull(controller).id
        val intent = Intent(this, PageMediaService::class.java).putExtra(CONTROLLER, controllerId)
            .setData(Uri.Builder().scheme("yab-media").authority(controllerId).appendPath(owner.session).appendPath(owner.document).appendPath(owner.tabId).appendPath(command.action.name).build())
        addCommand(intent, owner, command)
        return PendingIntent.getForegroundService(this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private fun openActivity(): PendingIntent = PendingIntent.getActivity(this, 0,
        Intent(this, MainActivity::class.java).setAction(Intent.ACTION_MAIN).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun releaseSession() { session?.isActive = false; session?.release(); session = null }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onTaskRemoved(rootIntent: Intent?) { current?.let { controller?.stopOwner(it.owner) }; stopSelf() }
    override fun onDestroy() {
        observer?.cancel(); scope.cancel(); releaseSession()
        handler.removeCallbacksAndMessages(null)
        stopForeground(STOP_FOREGROUND_REMOVE); notifications.cancel(NOTIFICATION_ID)
        controller?.serviceGone(); controller = null; current = null
        super.onDestroy()
    }

    companion object {
        const val CONTROLLER = "mediaController"
        const val NOTIFICATION_ID = 1418
        private const val CHANNEL = "page-playback"
        internal fun addCommand(intent: Intent, owner: MediaOwner, command: MediaCommand) {
            intent.putExtra("tab", owner.tabId).putExtra("document", owner.document).putExtra("session", owner.session)
                .putExtra("private", owner.privateOrigin).putExtra("command", command.action.name)
            command.positionSeconds?.let { intent.putExtra("position", it) }
        }
        private fun command(intent: Intent?): Pair<MediaOwner, MediaCommand>? = runCatching {
            if (intent?.hasExtra("command") != true) return null
            val owner = MediaOwner(requireNotNull(intent.getStringExtra("tab")), requireNotNull(intent.getStringExtra("document")),
                requireNotNull(intent.getStringExtra("session")), intent.getBooleanExtra("private", false))
            val action = MediaAction.valueOf(requireNotNull(intent.getStringExtra("command")))
            owner to MediaCommand(action, if (intent.hasExtra("position")) intent.getDoubleExtra("position", -1.0) else null)
        }.getOrNull()
        private fun milliseconds(value: Double): Long = if (!value.isFinite()) 0 else (value.coerceIn(0.0, Long.MAX_VALUE / 1000.0) * 1000).toLong()
        private fun MediaAction.platformAction(): Long = when (this) {
            MediaAction.PLAY -> PlaybackState.ACTION_PLAY
            MediaAction.PAUSE -> PlaybackState.ACTION_PAUSE
            MediaAction.STOP -> PlaybackState.ACTION_STOP
            MediaAction.SEEK_TO -> PlaybackState.ACTION_SEEK_TO
            MediaAction.SEEK_FORWARD -> PlaybackState.ACTION_FAST_FORWARD
            MediaAction.SEEK_BACKWARD -> PlaybackState.ACTION_REWIND
            MediaAction.NEXT -> PlaybackState.ACTION_SKIP_TO_NEXT
            MediaAction.PREVIOUS -> PlaybackState.ACTION_SKIP_TO_PREVIOUS
        }
    }
}

package dev.yab.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.IBinder
import android.os.Build
import androidx.core.content.ContextCompat
import kotlinx.coroutines.*

/** Foreground lifetime for an existing native response, never a URL downloader or restart worker. */
class PageDownloadService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var controller: PageDownloadController? = null
    private var download: String? = null
    private var observer: Job? = null
    private val notifications get() = getSystemService(NotificationManager::class.java)
    override fun onCreate() {
        super.onCreate()
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "Page downloads", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val next = PageDownloadRegistry.get(intent?.getStringExtra(CONTROLLER))
        if (next == null) {
            if (controller?.state?.value?.phase != PageDownloadPhase.TRANSFERRING) stopSelf(startId)
            return START_NOT_STICKY
        }
        val requested = intent?.getStringExtra(DOWNLOAD)
        if (requested == null || requested != next.state.value.id) {
            if (controller?.state?.value?.phase != PageDownloadPhase.TRANSFERRING) stopSelf(startId)
            return START_NOT_STICKY
        }
        controller = next
        download = requested
        try { startForeground(NOTIFICATION, notification(next.state.value), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) }
        catch (_: RuntimeException) { next.serviceFailed(); stopSelf(startId); return START_NOT_STICKY }
        if (intent?.action == CANCEL) next.cancel(intent.getStringExtra(DOWNLOAD))
        observer?.cancel()
        observer = scope.launch { next.state.collect { value ->
            if (value.id != requested) return@collect
            if (value.phase == PageDownloadPhase.TRANSFERRING) {
                if (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(this@PageDownloadService, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
                    notifications.notify(NOTIFICATION, notification(value))
            }
            else { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        } }
        return START_NOT_STICKY
    }
    private fun notification(value: PageDownloadState): Notification {
        val owner = value.owner
        val private = owner?.privateOrigin == true
        val controllerId = controller?.id.orEmpty()
        val cancel = Intent(this, PageDownloadService::class.java).setAction(CANCEL)
            .setData(Uri.Builder().scheme("yab-download").authority(controllerId).appendPath(value.id.orEmpty()).build())
            .putExtra(CONTROLLER, controllerId).putExtra(DOWNLOAD, value.id)
        val pendingCancel = PendingIntent.getService(this, 0, cancel, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val total = value.total?.takeIf { it > 0 }
        val progress = if (total == null) 0 else ((value.received.toDouble() / total) * 100).toInt().coerceIn(0, 100)
        return Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_yab)
            .setContentTitle(if (private) "Yab download" else value.name.ifBlank { "Yab download" })
            .setContentText(if (total == null) "Downloading a file" else "Downloading $progress%")
            .setProgress(100, progress, total == null).setCategory(Notification.CATEGORY_PROGRESS)
            .setVisibility(if (private) Notification.VISIBILITY_SECRET else Notification.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true).setOngoing(true).setContentIntent(open)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "Cancel", pendingCancel).build()).build()
    }
    override fun onTimeout(startId: Int, fgsType: Int) { controller?.serviceFailed(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(startId) }
    override fun onTaskRemoved(rootIntent: Intent?) { controller?.cancel(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
    override fun onDestroy() {
        controller?.takeIf { it.state.value.id == download && it.state.value.phase == PageDownloadPhase.TRANSFERRING }?.serviceFailed()
        observer?.cancel(); scope.cancel(); stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    companion object {
        const val CONTROLLER = "controller"
        internal const val DOWNLOAD = "download"
        private const val CANCEL = "dev.yab.download.CANCEL"
        private const val CHANNEL = "yab-page-downloads"
        private const val NOTIFICATION = 18431
    }
}

package dev.yab.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageInstaller
import androidx.core.content.IntentCompat
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

class UpdateDownloadWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val updater = AppUpdater.get(applicationContext)
        if (!updater.download { isStopped }) return Result.success()
        if (runAttemptCount < MAX_ATTEMPTS) return Result.retry()
        updater.abandonDownload()
        return Result.success()
    }

    private companion object { const val MAX_ATTEMPTS = 5 }
}

class UpdateApplyWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = if (AppUpdater.get(applicationContext).apply()) Result.retry() else Result.success()
}

/** The installer's answers. On success of an update this process is usually gone before it arrives. */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val session = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val code = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val confirm = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java)
        val pending = goAsync()
        AppUpdater.get(context).installResult(session, code, confirm).invokeOnCompletion { pending.finish() }
    }

    companion object {
        fun sender(context: Context, session: Int): IntentSender {
            val intent = Intent(context, UpdateInstallReceiver::class.java).setPackage(context.packageName)
            return PendingIntent.getBroadcast(context, session, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE).intentSender
        }
    }
}

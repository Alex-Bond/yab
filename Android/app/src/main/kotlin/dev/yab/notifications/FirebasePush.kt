package dev.yab.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dev.yab.agent.ApprovalRequest
import dev.yab.sync.AndroidSyncBridge
import kotlinx.coroutines.CancellationException

interface NotificationSyncPort {
    val account: String?
    suspend fun register(token: String, alerts: Boolean): Boolean
    suspend fun wake(): Boolean
    suspend fun finish()
    suspend fun open(name: String, blob: String): ApprovalRequest?
    fun currentApproval(id: String): ApprovalRequest?
}

class AndroidNotificationSyncPort(private val sync: AndroidSyncBridge) : NotificationSyncPort {
    override val account get() = sync.ui.value.account
    override suspend fun register(token: String, alerts: Boolean) = sync.registerPushToken(token, alerts)
    override suspend fun wake() = sync.wakeFromPush()
    override suspend fun finish() = sync.finishPushWake()
    override suspend fun open(name: String, blob: String) = sync.openPushApproval(name, blob)
    override fun currentApproval(id: String) = sync.approvals.value.firstOrNull { it.id == id }
}

/** Firebase is optional. Empty resources leave push unconfigured, without inventing an account or token. */
object PushNotifications {
    private const val CHANNEL = "mac-approvals"
    @Volatile var sync: NotificationSyncPort? = null
        private set
    @Volatile var configured: Boolean = false
        private set

    fun initialize(context: Context, port: NotificationSyncPort) {
        sync = port
        val app = context.applicationContext
        fun value(name: String): String {
            val id = app.resources.getIdentifier(name, "string", app.packageName)
            return if (id == 0) "" else app.getString(id)
        }
        val applicationId = value("firebase_app_id")
        val apiKey = value("firebase_api_key")
        val project = value("firebase_project_id")
        val sender = value("firebase_sender_id")
        if (listOf(applicationId, apiKey, project, sender).any(String::isBlank)) { configured = false; return }
        try {
            val existing = FirebaseApp.getApps(app).firstOrNull { it.name == FirebaseApp.DEFAULT_APP_NAME }
            if (existing == null) FirebaseApp.initializeApp(app, FirebaseOptions.Builder().setApplicationId(applicationId).setApiKey(apiKey).setProjectId(project).setGcmSenderId(sender).build())
            configured = true
            channel(app)
            FirebaseMessaging.getInstance().isAutoInitEnabled = true
            FirebaseMessaging.getInstance().token.addOnSuccessListener { token -> tokenArrived(app, token) }
        } catch (_: Exception) { configured = false }
    }

    fun tokenArrived(context: Context, token: String) {
        if (token.isBlank() || token.length > 4096) return
        context.getSharedPreferences("push", Context.MODE_PRIVATE).edit().putString("pendingToken", token).apply()
        WorkManager.getInstance(context).enqueueUniqueWork("fcm-token-registration", ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<PushRegistrationWorker>().build())
    }
    fun refreshRegistration(context: Context) {
        val token = context.getSharedPreferences("push", Context.MODE_PRIVATE).getString("pendingToken", null) ?: return
        tokenArrived(context, token)
    }
    fun receive(context: Context, data: Map<String, String>) {
        val envelope = PushEnvelope.read(data) ?: return
        val input = Data.Builder().putString("v", "1").putString("kind", when (envelope.kind) { PushEnvelope.Kind.SYNC -> "sync"; PushEnvelope.Kind.APPROVAL -> "approval"; PushEnvelope.Kind.WITHDRAW -> "withdraw" })
            .apply { envelope.approval?.let { putString("approval", it) }; envelope.name?.let { putString("n", it) }; envelope.blob?.let { putString("b", it) } }.build()
        val request = OneTimeWorkRequestBuilder<PushWakeWorker>().setInputData(input).apply {
            if (envelope.kind == PushEnvelope.Kind.APPROVAL) setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        }.build()
        WorkManager.getInstance(context).enqueueUniqueWork("fcm-${envelope.approval ?: "sync"}", ExistingWorkPolicy.REPLACE, request)
    }
    fun allowed(context: Context): Boolean = (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) && NotificationManagerCompat.from(context).areNotificationsEnabled()

    internal fun show(context: Context, words: NotificationWords, account: String?) {
        if (!allowed(context)) return
        channel(context)
        val prefs = context.getSharedPreferences("push", Context.MODE_PRIVATE)
        val key = NotificationPolicy.ledgerKey(account, words.id)
        val now = System.currentTimeMillis()
        val timestamp = prefs.getLong("announced.$key", 0)
        val announced = timestamp > 0 && now - timestamp in 0..172_800_000
        if (announced && (!words.validated || prefs.getBoolean("validated.$key", false))) return
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        launch.action = Intent.ACTION_VIEW
        launch.data = Uri.parse("yab://approval/${Uri.encode(words.id)}")
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(context, words.id.hashCode(), launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val public = NotificationCompat.Builder(context, CHANNEL).setSmallIcon(icon(context)).setContentTitle("Yab").setContentText("Needs your answer").setContentIntent(pending).build()
        val notice = NotificationCompat.Builder(context, CHANNEL).setSmallIcon(icon(context)).setContentTitle(words.title).setContentText(words.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(words.body)).setContentIntent(pending).setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE).setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(public).setOnlyAlertOnce(true).setSilent(announced).build()
        try {
            NotificationManagerCompat.from(context).notify("approval:${words.id}", 0, notice)
            prefs.edit().putLong("announced.$key", now).putBoolean("validated.$key", words.validated).apply()
        } catch (_: SecurityException) { }
    }
    internal fun withdraw(context: Context, id: String) { NotificationManagerCompat.from(context).cancel("approval:$id", 0) }
    private fun icon(context: Context): Int = context.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_dialog_info
    private fun channel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Questions from your Mac", NotificationManager.IMPORTANCE_HIGH).apply { description = "Approvals requested by the agent on your paired Mac"; lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE })
    }
}

class YabMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) { PushNotifications.tokenArrived(this, token) }
    override fun onMessageReceived(message: RemoteMessage) { PushNotifications.receive(this, message.data) }
    override fun onDeletedMessages() { PushNotifications.receive(this, mapOf("v" to "1", "kind" to "sync")) }
}

class PushRegistrationWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        if (!PushNotifications.configured) return Result.success()
        val port = PushNotifications.sync ?: return Result.retry()
        val token = applicationContext.getSharedPreferences("push", Context.MODE_PRIVATE).getString("pendingToken", null) ?: return Result.success()
        return try { if (port.register(token, PushNotifications.allowed(applicationContext))) Result.success() else Result.retry() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { Result.retry() }
    }
}

class PushWakeWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val data = inputData.keyValueMap.mapNotNull { (key, value) -> (value as? String)?.let { key to it } }.toMap()
        val envelope = PushEnvelope.read(data) ?: return Result.success()
        val port = PushNotifications.sync
        if (envelope.kind == PushEnvelope.Kind.WITHDRAW) envelope.approval?.let { PushNotifications.withdraw(applicationContext, it) }
        try {
            val caughtUp = port?.wake() == true
            if (envelope.kind == PushEnvelope.Kind.APPROVAL) {
                // A complete current journal knows a question was withdrawn,
                // answered or expired. A delayed push cannot ring it again.
                if (caughtUp && envelope.approval?.let { port?.currentApproval(it) } == null) return Result.success()
                val request = if (caughtUp && port != null) {
                    if (envelope.name != null && envelope.blob != null) port.open(envelope.name, envelope.blob)
                    else envelope.approval?.let(port::currentApproval)
                } else null
                val words = NotificationPolicy.words(envelope, request?.id, request?.title, request?.summary)
                if (words != null) PushNotifications.show(applicationContext, words, port?.account)
            }
            return Result.success()
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) {
            NotificationPolicy.words(envelope, null, null, null)?.let { PushNotifications.show(applicationContext, it, port?.account) }
            return Result.success()
        } finally { port?.finish() }
    }
}

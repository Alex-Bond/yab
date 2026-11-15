package dev.yab.update

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkRequest
import dev.yab.android.BuildConfig
import dev.yab.android.MainActivity
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request

/** What the Settings row says. */
enum class UpdateStatus(val words: String?) {
    IDLE(null), CHECKING("Checking…"), UP_TO_DATE("Up to Date"), WAITING("Waiting for Wi-Fi"), DOWNLOADING("Downloading"),
    READY("Ready to Install"), FAILED("Update Failed"), UNREACHABLE("Couldn't Check"),
}

/**
 * Keeps a sideloaded Yab current from the site: reads latest.json, fetches a newer APK on an unmetered
 * network, checks its SHA-256 and installs it through PackageInstaller while Yab is not in front. Android
 * refuses a different signature; nothing here works around that. All state changes run on [serial].
 */
class AppUpdater private constructor(private val app: Application) {
    @OptIn(ExperimentalCoroutinesApi::class)
    private val serial = Dispatchers.IO.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + serial)
    private val preferences = app.getSharedPreferences("yab-updates", Context.MODE_PRIVATE)
    private val codec = Json { ignoreUnknownKeys = true }
    private val folder = File(app.filesDir, "updates")
    private val client by lazy {
        OkHttpClient.Builder().connectTimeout(20, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build()
    }
    private val status = MutableStateFlow(UpdateStatus.IDLE)
    val state: StateFlow<UpdateStatus> = status

    val endpoint: UpdateEndpoint? by lazy {
        UpdateChannel.resolve(BuildConfig.DEBUG, app.packageName, certificates(), if (BuildConfig.DEBUG) setting("yab_update_base") else null)
    }
    private val quietMillis: Long get() = debugNumber("yab_update_quiet_seconds")?.times(1000) ?: UpdatePolicy.QUIET_MILLIS

    @Volatile private var started = 0
    @Volatile private var leftAt = 0L
    @Volatile private var transferring = false
    @Volatile private var promptIntent: Intent? = null
    private var launched = false
    private var confirmed = false

    private fun install() {
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) { if (++started == 1) entered() }
            override fun onActivityStopped(activity: Activity) { if (--started == 0 && !activity.isChangingConfigurations) left() }
            override fun onActivityResumed(activity: Activity) { if (activity is MainActivity) offerPrompt(activity) }
            override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
        scope.launch { if (endpoint != null) settle() }
    }

    private fun entered() {
        if (endpoint == null) { trace("off: this build does not update itself"); return }
        WorkManager.getInstance(app).cancelUniqueWork(APPLY)
        if (launched) return
        launched = true
        scope.launch {
            write(read().let { it.copy(launch = it.launch + 1) })
            settle()
            while (true) { check(manual = false); delay(UpdatePolicy.CHECK_PERIOD_MILLIS) }
        }
    }

    private fun left() {
        leftAt = SystemClock.elapsedRealtime()
        if (endpoint != null) scope.launch { if (read().stage == UpdateStage.READY) scheduleApply(quietMillis) }
    }

    fun checkNow() { if (endpoint != null) scope.launch { check(manual = true) } }

    private fun check(manual: Boolean) {
        val endpoint = endpoint ?: return
        if (manual) status.value = UpdateStatus.CHECKING
        val text = runCatching { manifest(endpoint) }.getOrNull()
        val offer = text?.let { UpdateManifest.parse(it, endpoint) }
        trace("manifest read, offer ${offer?.versionCode}")
        if (offer == null) { if (manual) status.value = UpdateStatus.UNREACHABLE; return }
        confirmed = true
        val decision = UpdatePolicy.afterManifest(read(), offer, installedCode(), Build.VERSION.SDK_INT, System.currentTimeMillis(), manual)
        write(decision.record)
        if (decision.discard) deleteFiles()
        when (decision.action) {
            UpdateAction.DOWNLOAD -> scheduleDownload()
            UpdateAction.APPLY -> if (started == 0) scheduleApply(quietLeft())
            UpdateAction.NOTHING -> Unit
        }
        publish()
    }

    private fun manifest(endpoint: UpdateEndpoint): String? {
        val strict = client.newBuilder().followRedirects(false).followSslRedirects(false).build()
        val request = Request.Builder().url(endpoint.manifestUrl).header("Cache-Control", "no-cache").build()
        strict.newCall(request).execute().use { response ->
            if (response.code != 200) return null
            val source = response.body?.source() ?: return null
            if (source.request(UpdateManifest.MAX_BYTES + 1)) return null
            return source.readUtf8()
        }
    }

    /** Runs in [UpdateDownloadWorker]. Returns true when WorkManager should try again later. */
    internal suspend fun download(stopped: () -> Boolean): Boolean = withContext(serial) {
        val endpoint = endpoint ?: return@withContext false
        val record = read()
        val offer = record.offer?.takeIf { record.stage == UpdateStage.DOWNLOADING } ?: return@withContext false
        transferring = true
        publish()
        val result = try {
            withContext(Dispatchers.IO) { UpdateDownloader(client, endpoint).fetch(offer, File(folder, "yab-${offer.versionCode}.part"), apkFile(offer), stopped) }
        } finally { transferring = false }
        trace("download of ${offer.versionCode}: $result")
        if (read().offer != offer) { deleteFiles(); publish(); return@withContext false }
        when (result) {
            UpdateDownloadResult.VERIFIED -> { write(read().copy(stage = UpdateStage.READY)); if (started == 0) scheduleApply(quietLeft()) }
            UpdateDownloadResult.REFUSED -> giveUp()
            UpdateDownloadResult.TRY_AGAIN -> Unit
        }
        publish()
        result == UpdateDownloadResult.TRY_AGAIN
    }

    internal suspend fun abandonDownload() = withContext(serial) { if (read().stage == UpdateStage.DOWNLOADING) giveUp(); publish() }

    /** Runs in [UpdateApplyWorker]. Returns true when something still holds the update back. */
    internal suspend fun apply(): Boolean {
        val record = withContext(serial) { read() }
        val offer = record.offer?.takeIf { record.stage == UpdateStage.READY } ?: return false
        if (started > 0) return false
        val hold = quietLeft() > 0 || withContext(Dispatchers.Main) { UpdateHolds.reason() }?.also { trace("held: $it") } != null
        if (hold || started > 0) return hold
        return withContext(serial) { commit(offer); false }
    }

    private fun commit(offer: UpdateOffer) {
        val apk = apkFile(offer)
        val archive = app.packageManager.getPackageArchiveInfo(apk.path, 0)
        if (archive == null || archive.packageName != app.packageName || archive.longVersionCode != offer.versionCode.toLong()) {
            trace("the APK is not version ${offer.versionCode} of this app"); giveUp(); publish(); return
        }
        val installer = app.packageManager.packageInstaller
        var session = -1
        try {
            val parameters = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(app.packageName)
                setSize(apk.length())
                if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
            session = installer.createSession(parameters)
            installer.openSession(session).use { open ->
                val digest = MessageDigest.getInstance("SHA-256")
                open.openWrite("base.apk", 0, apk.length()).use { output ->
                    apk.inputStream().use { input ->
                        val buffer = ByteArray(1024 * 1024)
                        while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count); output.write(buffer, 0, count) }
                    }
                    output.flush(); open.fsync(output)
                }
                check(UpdateDownloader.hex(digest.digest()) == offer.sha256) { "The APK changed on disk" }
                write(read().copy(stage = UpdateStage.INSTALLING, session = session))
                open.commit(UpdateInstallReceiver.sender(app, session))
            }
            trace("committed session for ${offer.versionCode}")
            apk.delete()
        } catch (failure: Exception) {
            if (failure !is IOException && failure !is SecurityException && failure !is IllegalStateException && failure !is IllegalArgumentException) throw failure
            trace("session failed: ${failure.javaClass.simpleName}")
            if (session >= 0) runCatching { installer.abandonSession(session) }
            giveUp()
        }
        publish()
    }

    /** From [UpdateInstallReceiver]. */
    internal fun installResult(session: Int, code: Int, confirm: Intent?) = scope.launch {
        val record = read()
        if (record.session != session) return@launch
        trace("install status $code")
        when (code) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                promptIntent = confirm
                write(record.copy(stage = UpdateStage.NEEDS_PROMPT, prompt = confirm?.toUri(0)))
            }
            PackageInstaller.STATUS_SUCCESS -> { write(UpdateRecord(launch = record.launch)); deleteFiles() }
            else -> { runCatching { app.packageManager.packageInstaller.abandonSession(session) }; giveUp() }
        }
        publish()
    }

    /** The system's question waits for the person to open Yab, and shows once per launch of the question. */
    private fun offerPrompt(activity: Activity) {
        if (endpoint == null) return
        scope.launch {
            val record = read()
            if (record.stage != UpdateStage.NEEDS_PROMPT) return@launch
            val intent = promptIntent ?: record.prompt?.let { runCatching { Intent.parseUri(it, 0) }.getOrNull() }
            val shown = withContext(Dispatchers.Main) {
                if (UpdateHolds.reason() != null || activity.isFinishing || activity.isDestroyed) return@withContext null
                intent?.let { runCatching { activity.startActivity(it) }.isSuccess } ?: false
            } ?: return@launch
            trace("system prompt shown: $shown")
            if (shown) write(record.copy(stage = UpdateStage.PROMPTED, promptLaunch = record.launch))
            else { runCatching { app.packageManager.packageInstaller.abandonSession(record.session) }; giveUp() }
            publish()
        }
    }

    private fun settle() {
        val record = read()
        val installer = app.packageManager.packageInstaller
        val committed = record.session >= 0 && installer.getSessionInfo(record.session)?.isCommitted == true
        if (UpdatePolicy.promptExpired(record)) {
            if (committed) runCatching { installer.abandonSession(record.session) }
            write(UpdatePolicy.fail(record, System.currentTimeMillis())); deleteFiles(); publish(); return
        }
        val decision = UpdatePolicy.reconcile(record, installedCode(), committed, System.currentTimeMillis())
        write(decision.record)
        for (own in installer.mySessions) if (own.sessionId != decision.record.session) runCatching { installer.abandonSession(own.sessionId) }
        if (decision.discard) deleteFiles()
        val live = decision.record.offer
        folder.listFiles()?.filter { live == null || !it.name.startsWith("yab-${live.versionCode}.") }?.forEach(File::delete)
        if (decision.record.stage == UpdateStage.DOWNLOADING) scheduleDownload()
        if (decision.action == UpdateAction.APPLY && started == 0) scheduleApply(quietLeft())
        publish()
    }

    private fun giveUp() { write(UpdatePolicy.fail(read(), System.currentTimeMillis())); deleteFiles() }

    private fun scheduleDownload() {
        val constraints = Constraints.Builder().setRequiredNetworkType(NetworkType.UNMETERED).setRequiresStorageNotLow(true).build()
        val request = OneTimeWorkRequestBuilder<UpdateDownloadWorker>().setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 5, TimeUnit.MINUTES).build()
        WorkManager.getInstance(app).enqueueUniqueWork(DOWNLOAD, ExistingWorkPolicy.KEEP, request)
    }

    private fun scheduleApply(delayMillis: Long) {
        val retry = max(WorkRequest.MIN_BACKOFF_MILLIS, quietMillis)
        val request: OneTimeWorkRequest = OneTimeWorkRequestBuilder<UpdateApplyWorker>().setInitialDelay(delayMillis, TimeUnit.MILLISECONDS)
            .setBackoffCriteria(BackoffPolicy.LINEAR, retry, TimeUnit.MILLISECONDS).build()
        WorkManager.getInstance(app).enqueueUniqueWork(APPLY, ExistingWorkPolicy.REPLACE, request)
    }

    private fun quietLeft() = if (leftAt == 0L) 0L else (quietMillis - (SystemClock.elapsedRealtime() - leftAt)).coerceAtLeast(0)

    private fun publish(override: UpdateStatus? = null) {
        val record = read()
        status.value = override ?: when {
            record.stage == UpdateStage.DOWNLOADING -> if (transferring) UpdateStatus.DOWNLOADING else UpdateStatus.WAITING
            record.stage != UpdateStage.NONE -> UpdateStatus.READY
            record.failure != null -> UpdateStatus.FAILED
            confirmed -> UpdateStatus.UP_TO_DATE
            else -> status.value.takeUnless { it == UpdateStatus.CHECKING } ?: UpdateStatus.IDLE
        }
        trace("state ${status.value} stage ${record.stage}")
    }

    private fun apkFile(offer: UpdateOffer) = File(folder, "yab-${offer.versionCode}.apk").also { folder.mkdirs() }
    private fun deleteFiles() { folder.listFiles()?.forEach(File::delete) }
    private fun installedCode() = app.packageManager.getPackageInfo(app.packageName, 0).longVersionCode

    private fun read(): UpdateRecord = preferences.getString(RECORD, null)
        ?.let { runCatching { codec.decodeFromString<UpdateRecord>(it) }.getOrNull() } ?: UpdateRecord()
    private fun write(record: UpdateRecord) { preferences.edit().putString(RECORD, codec.encodeToString(record)).commit() }

    private fun certificates(): List<String> {
        val info: PackageInfo = app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        val signing = info.signingInfo ?: return emptyList()
        val signers = if (signing.hasMultipleSigners()) signing.apkContentsSigners else signing.signingCertificateHistory
        return signers.orEmpty().map { UpdateDownloader.hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }
    }

    private fun setting(name: String) = if (BuildConfig.DEBUG) Settings.Global.getString(app.contentResolver, name) else null
    private fun debugNumber(name: String) = setting(name)?.toLongOrNull()
    private fun trace(line: String) { if (BuildConfig.DEBUG) android.util.Log.d("YabUpdate", line) }

    companion object {
        private const val RECORD = "record"
        private const val DOWNLOAD = "yab-update-download"
        private const val APPLY = "yab-update-apply"
        @Volatile private var instance: AppUpdater? = null

        fun get(context: Context): AppUpdater = instance ?: synchronized(this) {
            instance ?: AppUpdater(context.applicationContext as Application).also { instance = it }
        }
        /** Once, from the main process's Application. */
        fun start(app: Application) { get(app).install() }
    }
}

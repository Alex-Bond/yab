package dev.yab.reports

import android.app.ActivityManager
import android.app.Application
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.AtomicFile
import dev.yab.android.BuildConfig
import java.io.Closeable
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import kotlin.system.exitProcess

class FileReportStore(private val file: File) : ReportStore {
    private val json = Json { ignoreUnknownKeys = true }
    // AtomicFile.openRead recovers by deleting a pending .new file. Its API
    // requires caller locking, so a read must not overlap this store's write.
    private val io = Mutex()
    override suspend fun load(): ReportSnapshot = io.withLock { withContext(Dispatchers.IO) {
        if (!file.exists()) ReportSnapshot() else json.decodeFromString<ReportSnapshot>(AtomicFile(file).openRead().bufferedReader().use { it.readText() })
    } }
    override suspend fun save(snapshot: ReportSnapshot) = io.withLock {
        withContext(Dispatchers.IO) { atomicWrite(file, json.encodeToString(snapshot)) }
    }
}

/** No cookies, persisted HTTP cache, redirects, account tokens, URLs or browser state. */
class ReportsHttpTransport(site: String) : ReportTransport {
    private val site = requireNotNull(site.toHttpUrlOrNull()?.takeIf { it.isHttps && it.username.isEmpty() && it.password.isEmpty() && it.query == null && it.fragment == null })
    private val client = OkHttpClient.Builder().cookieJar(CookieJar.NO_COOKIES).cache(null).followRedirects(false).followSslRedirects(false).build()
    override suspend fun post(request: ReportRequest): Boolean = withContext(Dispatchers.IO) {
        val url = site.newBuilder().addPathSegments(request.path).build()
        val outgoing = Request.Builder().url(url).header("Cache-Control", "no-store")
            .post(request.fields.toString().toRequestBody("application/json".toMediaType())).build()
        client.newBuilder().callTimeout(request.timeoutSeconds, TimeUnit.SECONDS).build().newCall(outgoing).execute().use { it.code == 200 }
    }
}

/** Debug and unconfigured builds never install collectors or construct a network transport. */
class AndroidReports(context: Context, private val scope: CoroutineScope) : Closeable {
    private val app = context.applicationContext
    private val folder = File(app.filesDir, "reports")
    private val metadata = metadata(app)
    private val site = configuredSite(app)
    val controller = ReportsController(FileReportStore(File(folder, "consent.json")), site?.let(::ReportsHttpTransport), metadata, scope)
    val state get() = controller.state
    private var watcher: Job? = null
    private var hourly: Job? = null
    private var previousHandler: Thread.UncaughtExceptionHandler? = null
    private var handler: Thread.UncaughtExceptionHandler? = null

    init {
        if (site != null && Application.getProcessName() == app.packageName) {
            watcher = scope.launch {
                if (controller.state.first { !it.loading }.available) {
                    installCrashCapture()
                    withContext(Dispatchers.IO) { importSavedCrashes() }
                }
            }
        }
    }
    fun foregrounded(mayAsk: Boolean) {
        controller.foregrounded(mayAsk)
        if (hourly?.isActive != true) hourly = scope.launch { while (isActive) { delay(60 * 60 * 1000L); controller.tick() } }
    }
    fun presentationAllowed(mayAsk: Boolean) = controller.setPresentationAllowed(mayAsk)
    fun backgrounded() { hourly?.cancel(); hourly = null; controller.backgrounded() }

    private fun installCrashCapture() {
        previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        handler = Thread.UncaughtExceptionHandler { thread, failure ->
            try {
                val at = System.currentTimeMillis()
                val frames = generateSequence(failure) { it.cause }.take(6).flatMap { it.stackTrace.asSequence() }.take(512)
                    .map { "${it.className}.${it.methodName}" + if (it.lineNumber >= 0) ":${it.lineNumber}" else "" }
                    .filter(ReportCode::jvm).toList()
                val crash = SavedCrash(key("jvm:$at:${failure.javaClass.name}"), metadata.version, metadata.build,
                    metadata.os, metadata.device, failure.javaClass.name, frames, at)
                atomicWrite(File(folder, "jvm-crash.json"), Json.encodeToString(crash))
            } catch (_: Throwable) { /* Report collection must never replace the real crash. */ }
            val previous = previousHandler
            if (previous != null) previous.uncaughtException(thread, failure)
            else { android.os.Process.killProcess(android.os.Process.myPid()); exitProcess(2) }
        }
        Thread.setDefaultUncaughtExceptionHandler(handler)
    }

    @Serializable private data class LastLaunch(val at: Long, val metadata: MetadataOnDisk)
    @Serializable private data class MetadataOnDisk(val version: String, val build: String, val os: String, val device: String)
    private suspend fun importSavedCrashes() {
        val json = Json { ignoreUnknownKeys = true }
        val raw = File(folder, "jvm-crash.json")
        val captured = runCatching { json.decodeFromString<SavedCrash>(raw.readText()) }.getOrNull()
        val stamp = File(folder, "last-launch.json")
        val previous = runCatching { json.decodeFromString<LastLaunch>(stamp.readText()) }.getOrNull()
        val crashes = mutableListOf<SavedCrash>()
        val observedExits = mutableListOf<ReportExitObservation>()
        captured?.let(crashes::add)
        // Read the OS stream only into bounded code-coordinate projections. Neither a raw trace
        // nor names, paths, descriptions, thread state, memory or exception text are saved.
        if (Build.VERSION.SDK_INT >= 30 && previous != null) {
            val declared = ownedExitProcesses(app)
            runCatching { requireNotNull(app.getSystemService(ActivityManager::class.java)).getHistoricalProcessExitReasons(app.packageName, 0, 10) }.getOrDefault(emptyList()).forEach { exit ->
                currentCoroutineContext().ensureActive()
                if (!ReportExitOwnership.owns(app.packageName, exit.processName, declared)) return@forEach
                ReportExitCounts.observation(exit.timestamp, exit.pid, exit.reason, exit.importance, exit.processName)?.let(observedExits::add)
                if (exit.timestamp < previous.at) return@forEach
                val reason = when (exit.reason) {
                    ApplicationExitInfo.REASON_CRASH -> if (captured != null && exit.processName == app.packageName) return@forEach else "ANDROID_CRASH"
                    ApplicationExitInfo.REASON_CRASH_NATIVE -> "ANDROID_NATIVE_CRASH"
                    ApplicationExitInfo.REASON_ANR -> "ANDROID_ANR"
                    else -> return@forEach
                }
                val trace = when (exit.reason) {
                    ApplicationExitInfo.REASON_CRASH_NATIVE -> if (Build.VERSION.SDK_INT >= 31)
                        ExitTraceReader.read(ExitTraceFormat.NATIVE_TOMBSTONE, exit.pid) { exit.traceInputStream }
                        else TraceProjection(ExitTrace(ExitTraceFormat.NATIVE_TOMBSTONE, TraceAvailability.UNSUPPORTED))
                    ApplicationExitInfo.REASON_ANR -> ExitTraceReader.read(ExitTraceFormat.ANR_TEXT, exit.pid) { exit.traceInputStream }
                    else -> null
                }
                val meta = previous.metadata
                crashes.add(SavedCrash(key("android:${exit.timestamp}:${exit.pid}:$reason"), meta.version, meta.build, meta.os, meta.device,
                    reason, trace?.frames.orEmpty(), exit.timestamp, CrashSource.ANDROID_EXIT, trace?.trace, kind = if (exit.reason == ApplicationExitInfo.REASON_ANR) ReportKind.HANG else ReportKind.CRASH))
            }
        }
        if (controller.received(crashes.sortedBy { it.at }, observedExits)) raw.delete()
        atomicWrite(stamp, Json.encodeToString(LastLaunch(System.currentTimeMillis(), MetadataOnDisk(metadata.version, metadata.build, metadata.os, metadata.device))))
    }

    override fun close() {
        hourly?.cancel(); watcher?.cancel(); controller.close()
        if (Thread.getDefaultUncaughtExceptionHandler() === handler) Thread.setDefaultUncaughtExceptionHandler(previousHandler)
        handler = null; previousHandler = null
    }

    companion object {
        internal fun ownedExitProcesses(context: Context): Set<String> = runCatching {
            context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_SERVICES).services.orEmpty()
                .filter { it.packageName == context.packageName }.mapNotNull { it.processName }.toSet()
        }.getOrDefault(emptySet())
        fun configuredSite(context: Context): String? {
            if (BuildConfig.DEBUG) return null
            val app = context.applicationContext
            val info = app.packageManager.getApplicationInfo(app.packageName, PackageManager.GET_META_DATA)
            return info.metaData?.getString("dev.yab.REPORTS_SITE")?.takeIf { text -> text.toHttpUrlOrNull()?.let { it.isHttps && it.username.isEmpty() && it.password.isEmpty() && it.query == null && it.fragment == null } == true }
        }
        fun metadata(context: Context): ReportMetadata {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            return ReportMetadata(info.versionName.orEmpty(), info.longVersionCode.toString(), "Android ${Build.VERSION.RELEASE} API ${Build.VERSION.SDK_INT}", Build.MODEL, context.packageName)
        }
        private fun key(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}

private fun atomicWrite(file: File, text: String) {
    file.parentFile?.mkdirs()
    val atomic = AtomicFile(file)
    val stream = atomic.startWrite()
    try { stream.write(text.toByteArray()); atomic.finishWrite(stream) }
    catch (failure: Throwable) { atomic.failWrite(stream); throw failure }
}

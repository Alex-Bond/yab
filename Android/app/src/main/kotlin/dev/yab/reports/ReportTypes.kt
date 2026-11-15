package dev.yab.reports

import java.time.Instant
import java.time.ZoneOffset
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.*

@Serializable enum class ReportKind { @SerialName("crash") CRASH, @SerialName("hang") HANG }

@Serializable
data class SavedCrash(val key: String, val version: String, val build: String, val os: String,
    val device: String, val reason: String, val frames: List<String>, val at: Long, val source: CrashSource = CrashSource.JVM,
    val trace: ExitTrace? = null, val kind: ReportKind = ReportKind.CRASH) {
    val isHang: Boolean get() = kind == ReportKind.HANG
}
@Serializable enum class CrashSource { JVM, ANDROID_EXIT }

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class ReportSnapshot(val automaticCrashes: Boolean = false, val dailyActivity: Boolean = true,
    val installation: String? = null, val lastDay: String? = null, val person: String? = null,
    val since: Long = 0, val email: String = "", val pending: List<SavedCrash> = emptyList(),
    val allowed: Set<String> = emptySet(), val seen: List<String> = emptyList(),
    @EncodeDefault(EncodeDefault.Mode.NEVER) val exitCounts: ReportExitLedger = ReportExitLedger())

data class ReportMetadata(val version: String, val build: String, val os: String, val device: String, val packageName: String)
data class ReportRequest(val path: String, val fields: JsonObject, val timeoutSeconds: Long)
fun interface ReportTransport { suspend fun post(request: ReportRequest): Boolean }
interface ReportStore { suspend fun load(): ReportSnapshot; suspend fun save(snapshot: ReportSnapshot) }
data class CrashQuestion(val token: String, val keys: Set<String>, val exitKeys: Set<String> = emptySet())
enum class FeedbackStatus { IDLE, SENDING, SENT, FAILED }
data class ReportsState(val loading: Boolean = true, val available: Boolean = false, val automaticCrashes: Boolean = false,
    val dailyActivity: Boolean = true, val question: CrashQuestion? = null, val draft: String = "", val email: String = "",
    val feedback: FeedbackStatus = FeedbackStatus.IDLE, val feedbackError: String? = null, val storageError: String? = null)

object ReportWire {
    val uuid = Regex("(?i)[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    fun day(now: Long): String = Instant.ofEpochMilli(now).atZone(ZoneOffset.UTC).toLocalDate().toString()
    fun activity(id: String, person: String?) = ReportRequest("api/activity", buildJsonObject {
        put("id", id); put("platform", "android")
        person?.takeIf(uuid::matches)?.let { put("person", it) }
    }, 10)
    fun reportText(crash: SavedCrash, observedExits: List<ReportExitContribution> = emptyList()): String {
        val head = buildJsonObject {
            put("app_name", "Yab"); put("app_version", crash.version.take(32)); put("build_version", crash.build.take(32)); put("platform", "android"); put("os_version", crash.os.take(64)); put("device", crash.device.take(100))
            if (crash.isHang) put("kind", "hang")
        }
        val native = crash.trace?.takeIf { it.format == ExitTraceFormat.NATIVE_TOMBSTONE }?.nativeFrames.orEmpty()
            .filter(ReportCode::native).take(ReportCode.MAX_FRAMES)
        val images = native.map { it.library to it.buildId.lowercase() }.distinct()
        val body = buildJsonObject {
            put("source", if (crash.source == CrashSource.JVM) "Android JVM" else "Android exit")
            ReportExitCounts.wire(observedExits)?.let { put("observedExitCounts", it) }
            put("exception", buildJsonObject { put("type", crash.reason.takeIf(ReportCode::jvm) ?: "ANDROID_CRASH") })
            crash.trace?.let { trace -> put("androidTrace", buildJsonObject {
                put("version", 1); put("format", trace.format.name); put("availability", trace.availability.name)
            }) }
            put("faultingThread", 0)
            put("usedImages", buildJsonArray {
                if (crash.trace?.format != ExitTraceFormat.NATIVE_TOMBSTONE) add(buildJsonObject { put("name", "Yab") })
                else images.forEach { (name, id) -> add(buildJsonObject { put("name", name); put("buildId", id) }) }
            })
            put("threads", buildJsonArray { add(buildJsonObject {
                put("triggered", true); put("frames", buildJsonArray {
                    if (crash.trace?.format == ExitTraceFormat.NATIVE_TOMBSTONE) native.forEach { frame ->
                        add(buildJsonObject { put("imageIndex", images.indexOf(frame.library to frame.buildId.lowercase())); put("imageOffset", frame.offset) })
                    } else crash.frames.asSequence().filter(ReportCode::jvm).take(ReportCode.MAX_FRAMES).forEach { symbol ->
                        add(buildJsonObject { put("imageIndex", 0); put("symbol", symbol) }) }
                })
            }) })
        }
        return "$head\n$body"
    }
    fun crash(crash: SavedCrash, observedExits: List<ReportExitContribution> = emptyList()) = ReportRequest("api/crash", buildJsonObject {
        val report = reportText(crash, observedExits)
        put("platform", "android"); put("version", crash.version); put("build", crash.build)
        put("os", crash.os); put("device", crash.device); put("report", report); put("bytes", report.toByteArray(Charsets.UTF_8).size)
        if (crash.isHang) put("kind", "hang")
    }, 30)
    fun feedback(message: String, email: String, metadata: ReportMetadata) = ReportRequest("api/feedback", buildJsonObject {
        put("kind", "other"); put("message", message); put("email", email.trim()); put("version", metadata.version)
        put("build", metadata.build); put("os", "${metadata.os} ${metadata.device}".trim())
    }, 15)
}

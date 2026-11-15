package dev.yab.reports

import java.io.InputStream
import kotlinx.serialization.Serializable

@Serializable enum class ExitTraceFormat { ANR_TEXT, NATIVE_TOMBSTONE }
@Serializable enum class TraceAvailability { AVAILABLE, PARTIAL, UNAVAILABLE, UNSUPPORTED, MALFORMED, NO_CODE }
@Serializable data class NativeCodeFrame(val library: String, val buildId: String, val offset: Long)
@Serializable data class ExitTrace(val format: ExitTraceFormat, val availability: TraceAvailability,
    val nativeFrames: List<NativeCodeFrame> = emptyList())
data class TraceProjection(val trace: ExitTrace, val frames: List<String> = emptyList())

object ReportExitOwnership {
    /** Service process names come from this installed APK's PackageManager manifest, never a prefix-only guess. */
    fun owns(packageName: String, processName: String?, declaredProcesses: Set<String>): Boolean =
        processName == packageName || (processName != null && processName.startsWith("$packageName:") && processName in declaredProcesses)
}

/** Only code coordinates leave a parser. Paths, method arguments, names and unknown proto fields do not. */
object ReportCode {
    const val MAX_FRAMES = 512
    const val MAX_SAFE_OFFSET = 9_007_199_254_740_991L
    val nativeLibraries = setOf("libxul.so", "libmozglue.so", "libgkcodecs.so", "libmozavcodec.so", "libmozavutil.so",
        "liblgpllibs.so", "libnss3.so", "libfreebl3.so", "libsoftokn3.so", "libplugin-container.so", "libcrashhelper.so",
        "libcrashtools.so", "libclearkey.so", "libdatastore_shared_counter.so", "libsurface_util_jni.so", "liblitertlm_jni.so",
        "libtranslate_jni.so", "liblanguage_id_l2c_jni.so", "libbarhopper_v3.so", "libimage_processing_util_jni.so",
        "libandroidx.graphics.path.so", "libc.so", "libart.so", "libandroid_runtime.so", "libutils.so", "libc++.so", "liblog.so", "libdl.so", "libm.so")
    private val code = Regex("[A-Za-z_$][A-Za-z0-9_.$<>]*(?::[0-9]{1,10})?")
    private val buildId = Regex("[0-9a-fA-F]{8,128}")
    fun jvm(value: String): Boolean = value.length <= 240 && code.matches(value)
    fun native(frame: NativeCodeFrame): Boolean = frame.library in nativeLibraries && frame.offset in 0..MAX_SAFE_OFFSET &&
        frame.buildId.length % 2 == 0 && buildId.matches(frame.buildId)
    fun library(path: String): String? = path.takeIf { it.length <= 4096 && !it.contains("://") && it.none { c -> c <= '\u001f' || c == '\u007f' } }
        ?.substringAfterLast('/')?.takeIf { it in nativeLibraries }
}

/** Opening, reading and closing failures become fixed enums, never exception messages. No raw trace file is made. */
object ExitTraceReader {
    fun read(format: ExitTraceFormat, pid: Int, open: () -> InputStream?): TraceProjection = try {
        val input = open()
        if (input == null) TraceProjection(ExitTrace(format, TraceAvailability.UNAVAILABLE))
        else input.use { if (format == ExitTraceFormat.ANR_TEXT) AnrTraceParser.parse(it, pid) else NativeTombstoneParser.parse(it, pid) }
    } catch (_: Exception) { TraceProjection(ExitTrace(format, TraceAvailability.UNAVAILABLE)) }
}

/** Pinned ART DumpJavaStack syntax; selects the process and OS main tid, never a user-controlled thread name. */
object AnrTraceParser {
    private val process = Regex("----- pid ([0-9]{1,10}) at .+ -----")
    private val systemTid = Regex("\\s*\\| sysTid=([0-9]{1,10})(?: .*)?")
    private val frame = Regex("\\s+at ([A-Za-z0-9_.$<>]+)\\(([^()]*)\\)\\s*")
    private val source = Regex("[A-Za-z0-9_.$-]{1,180}:(-?[0-9]{1,10})")
    fun parse(input: InputStream, pid: Int): TraceProjection {
        if (pid <= 0) return TraceProjection(ExitTrace(ExitTraceFormat.ANR_TEXT, TraceAvailability.MALFORMED))
        val bytes = TraceBytes(input)
        val frames = ArrayList<String>()
        var inProcess = false
        var sawProcess = false
        var main = false
        var partial = false
        try {
            while (true) {
                val line = bytes.line() ?: break
                if (line == nullLine) { main = false; partial = true; continue }
                val owner = process.matchEntire(line)?.groupValues?.get(1)?.toIntOrNull()
                if (owner != null) { inProcess = owner == pid; sawProcess = sawProcess || inProcess; main = false; continue }
                if (!inProcess) continue
                if (line.startsWith("----- end ")) { inProcess = false; main = false; continue }
                if (line.startsWith('"')) { main = false; continue }
                val tid = systemTid.matchEntire(line)?.groupValues?.get(1)?.toIntOrNull()
                if (tid != null) { main = tid == pid; continue }
                if (!main) continue
                val match = frame.matchEntire(line) ?: continue
                val symbol = match.groupValues[1]
                val location = match.groupValues[2]
                val lineNumber = source.matchEntire(location)?.groupValues?.get(1)?.toIntOrNull()
                if (location != "Native method" && location != "Unknown Source" && lineNumber == null) continue
                val coordinate = symbol + if (lineNumber != null && lineNumber >= 0) ":$lineNumber" else ""
                if (ReportCode.jvm(coordinate)) {
                    if (frames.size == ReportCode.MAX_FRAMES) { partial = true; break }
                    frames.add(coordinate)
                }
            }
        } catch (_: TraceLimit) { partial = true }
        catch (_: Exception) { return TraceProjection(ExitTrace(ExitTraceFormat.ANR_TEXT, TraceAvailability.MALFORMED)) }
        val availability = when { partial -> TraceAvailability.PARTIAL; !sawProcess -> TraceAvailability.MALFORMED
            frames.isEmpty() -> TraceAvailability.NO_CODE; else -> TraceAvailability.AVAILABLE }
        return TraceProjection(ExitTrace(ExitTraceFormat.ANR_TEXT, availability), frames)
    }
}

private const val nullLine = "\u0000" // Overlong text is discarded, including any apparent frames it contains.
private class TraceLimit : Exception()
private class MalformedTrace : Exception()

private class TraceBytes(input: InputStream) {
    private val input = input.buffered(4096)
    var position = 0
        private set
    fun byte(): Int {
        if (position >= 1_048_576) throw TraceLimit()
        val byte = input.read()
        if (byte >= 0) position++
        return byte
    }
    fun required(): Int = byte().takeIf { it >= 0 } ?: throw MalformedTrace()
    fun line(): String? {
        val buffer = ByteArray(4096)
        var length = 0
        var tooLong = false
        while (true) {
            val value = byte()
            if (value < 0 && length == 0 && !tooLong) return null
            if (value < 0 || value == 10) break
            if (length < buffer.size) buffer[length++] = value.toByte() else tooLong = true
        }
        if (tooLong) return nullLine
        return String(buffer, 0, length, Charsets.UTF_8).trimEnd('\r')
    }
}

/** Minimal streaming reader for the official tombstone.proto, not Breakpad or a guessed text format. */
object NativeTombstoneParser {
    private data class ThreadFrames(val tid: Long, val frames: List<NativeCodeFrame>)
    fun parse(input: InputStream, expectedPid: Int): TraceProjection {
        val format = ExitTraceFormat.NATIVE_TOMBSTONE
        if (expectedPid <= 0) return TraceProjection(ExitTrace(format, TraceAvailability.MALFORMED))
        val bytes = TraceBytes(input)
        val budget = Budget()
        val root = Proto(bytes, null, budget)
        val threads = ArrayList<ThreadFrames>()
        var pid = 0L
        var tid = 0L
        var partial = false
        var coordinates = 0
        try {
            while (true) {
                val tag = root.tag() ?: break
                when (tag) {
                    5 shl 3 -> pid = root.number().toLong()
                    6 shl 3 -> tid = root.number().toLong()
                    (16 shl 3) or 2 -> root.message { entry ->
                        var key = 0L
                        var frames: List<NativeCodeFrame> = emptyList()
                        while (true) {
                            when (val field = entry.tag() ?: break) {
                                1 shl 3 -> key = entry.number().toLong()
                                (2 shl 3) or 2 -> entry.message { thread ->
                                    val projected = ArrayList<NativeCodeFrame>()
                                    while (true) {
                                        val next = thread.tag() ?: break
                                        if (next == ((4 shl 3) or 2)) thread.message { frame ->
                                            val coordinate = readFrame(frame)
                                            if (coordinate != null) {
                                                val size = coordinate.library.length + coordinate.buildId.length + 16
                                                if (projected.size < ReportCode.MAX_FRAMES && coordinates + size <= 131_072) {
                                                    coordinates += size; projected.add(coordinate)
                                                } else partial = true
                                            } else partial = true
                                        } else thread.skip(next)
                                    }
                                    frames = projected
                                }
                                else -> entry.skip(field)
                            }
                        }
                        if (threads.size < 64 && key > 0 && threads.none { it.tid == key }) threads.add(ThreadFrames(key, frames))
                        else partial = true
                    }
                    else -> root.skip(tag)
                }
            }
        } catch (_: TraceLimit) { partial = true }
        catch (_: Exception) { return TraceProjection(ExitTrace(format, TraceAvailability.MALFORMED)) }
        if (pid != expectedPid.toLong() || tid <= 0) return TraceProjection(ExitTrace(format, TraceAvailability.MALFORMED))
        val frames = threads.firstOrNull { it.tid == tid }?.frames.orEmpty()
        return TraceProjection(ExitTrace(format, when { partial -> TraceAvailability.PARTIAL; frames.isEmpty() -> TraceAvailability.NO_CODE
            else -> TraceAvailability.AVAILABLE }, frames))
    }

    private fun readFrame(frame: Proto): NativeCodeFrame? {
        var offset = 0uL // rel_pc=0 is a valid proto3 default, including when the field is absent.
        var name: String? = null
        var build: String? = null
        while (true) {
            when (val tag = frame.tag() ?: break) {
                1 shl 3 -> offset = frame.number()
                (6 shl 3) or 2 -> name = frame.text(4096)?.let(ReportCode::library)
                (8 shl 3) or 2 -> build = frame.text(128)?.lowercase()
                else -> frame.skip(tag) // Absolute pc/sp, function text and every unknown field are skipped.
            }
        }
        if (offset > ReportCode.MAX_SAFE_OFFSET.toULong()) return null
        return NativeCodeFrame(name ?: return null, build ?: return null, offset.toLong()).takeIf(ReportCode::native)
    }

    private class Budget { var fields = 0 }
    private class Proto(val bytes: TraceBytes, private val end: Int?, private val budget: Budget) {
        fun tag(): Int? {
            if (end != null && bytes.position == end) return null
            val first = bytes.byte()
            if (first < 0) { if (end != null) throw MalformedTrace(); return null }
            if (++budget.fields > 131_072) throw TraceLimit()
            val tag = varint(first)
            if (tag == 0uL || tag > Int.MAX_VALUE.toULong() || (tag shr 3) == 0uL) throw MalformedTrace()
            return tag.toInt()
        }
        fun number(): ULong = varint(required())
        private fun required(): Int { if (end != null && bytes.position >= end) throw MalformedTrace(); return bytes.required() }
        private fun varint(first: Int): ULong {
            var value = (first and 127).toULong()
            var current = first
            var shift = 7
            while (current and 128 != 0) {
                if (shift > 63) throw MalformedTrace()
                current = required()
                if (shift == 63 && current > 1) throw MalformedTrace()
                value = value or ((current and 127).toULong() shl shift)
                shift += 7
            }
            return value
        }
        private fun size(): Int {
            val size = number()
            if (size > 1_048_576uL) throw TraceLimit()
            val last = bytes.position + size.toInt()
            if (end != null && last > end) throw MalformedTrace()
            if (last > 1_048_576) throw TraceLimit()
            return size.toInt()
        }
        fun message(block: (Proto) -> Unit) {
            val length = size()
            val child = Proto(bytes, bytes.position + length, budget)
            block(child)
            if (bytes.position != child.end) throw MalformedTrace()
        }
        fun text(limit: Int): String? {
            val count = size()
            if (count > limit) { repeat(count) { required() }; return null }
            return String(ByteArray(count) { required().toByte() }, Charsets.UTF_8)
        }
        fun skip(tag: Int) {
            when (tag and 7) {
                0 -> number()
                1 -> repeat(8) { required() }
                2 -> { val count = size(); repeat(count) { required() } }
                5 -> repeat(4) { required() }
                else -> throw MalformedTrace()
            }
        }
    }
}

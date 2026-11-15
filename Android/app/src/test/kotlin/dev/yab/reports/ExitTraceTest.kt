package dev.yab.reports

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import kotlinx.coroutines.test.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ExitTraceTest {
    private val json = Json { ignoreUnknownKeys = true }
    private fun resource(name: String): ByteArray = requireNotNull(javaClass.getResourceAsStream("/reports/$name")).use { it.readBytes() }
    private fun saved(projection: TraceProjection) = SavedCrash("fixture", "0.1.0", "3", "Android fixture", "Fixture", "ANDROID_NATIVE_CRASH",
        projection.frames, 2, CrashSource.ANDROID_EXIT, projection.trace)

    @Test fun immutableFixturesMatchTheirManifest() {
        val files = json.parseToJsonElement(resource("fixtures.json").decodeToString()).jsonObject["files"]!!.jsonObject
        files.forEach { (name, expected) ->
            val data = resource(name)
            assertEquals(expected.jsonObject["bytes"]!!.jsonPrimitive.int, data.size)
            assertEquals(expected.jsonObject["sha256"]!!.jsonPrimitive.content,
                MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it.toInt() and 255) })
        }
    }

    @Test fun anrChoosesExactProcessAndSystemMainTidAndDiscardsAllOtherText() {
        val parsed = AnrTraceParser.parse(resource("anr.txt").inputStream(), 4242)
        assertEquals(TraceAvailability.AVAILABLE, parsed.trace.availability)
        assertEquals(listOf("dev.yab.Fixture.waitForPage:42", "java.lang.Object.wait"), parsed.frames)
        assertTrue(parsed.trace.nativeFrames.isEmpty())
        val text = json.encodeToString(saved(parsed)) + ReportWire.reportText(saved(parsed))
        for (marker in listOf("PRIVATE_", "private.example", "other.app", "/data/", "123456789abcdef0", "threadName", "register")) assertFalse(marker, text.contains(marker))
        assertEquals(TraceAvailability.MALFORMED, AnrTraceParser.parse(resource("anr.txt").inputStream(), 999).trace.availability)
    }

    @Test fun nativeOfficialProtoSelectsCrashTidAcrossArbitraryFieldOrderAndKeepsZeroRelativePc() {
        val parsed = NativeTombstoneParser.parse(resource("tombstone.pb").inputStream(), 4242)
        assertEquals(TraceAvailability.AVAILABLE, parsed.trace.availability)
        assertTrue(parsed.frames.isEmpty())
        assertEquals(listOf(NativeCodeFrame("libxul.so", "0123456789abcdef0123456789abcdef01234567", 4096),
            NativeCodeFrame("libmozglue.so", "abcdefabcdefabcdefabcdefabcdefabcdefabcd", 0)), parsed.trace.nativeFrames)
        val request = ReportWire.crash(saved(parsed))
        assertEquals(json.parseToJsonElement(resource("native-wire.json").decodeToString()), request.fields)
        val serialized = json.encodeToString(saved(parsed)) + request.fields.toString()
        for (marker in listOf("PRIVATE_", "private.example", "user@example", "data/app", "function_name", "threadName", "register", "memory", "pc\"", "sp\"")) assertFalse(marker, serialized.contains(marker))
        val body = json.parseToJsonElement(ReportWire.reportText(saved(parsed)).substringAfter('\n')).jsonObject
        assertFalse(body.toString().contains("symbol"))
        assertFalse(body.toString().contains("uuid"))
        assertEquals(setOf("name", "buildId"), body["usedImages"]!!.jsonArray[0].jsonObject.keys)
    }

    @Test fun missingOsTraceAndOpenReadCloseFailuresNeverExposeTheirMessages() {
        assertEquals(TraceAvailability.UNAVAILABLE, ExitTraceReader.read(ExitTraceFormat.ANR_TEXT, 1) { null }.trace.availability)
        assertEquals(TraceAvailability.UNAVAILABLE, ExitTraceReader.read(ExitTraceFormat.ANR_TEXT, 1) { throw IOException("PRIVATE_URL") }.trace.availability)
        var closed = false
        val failed = ExitTraceReader.read(ExitTraceFormat.NATIVE_TOMBSTONE, 1) {
            object : InputStream() {
                override fun read(): Int = throw IOException("PRIVATE_MEMORY")
                override fun close() { closed = true }
            }
        }
        assertTrue(closed)
        assertEquals(TraceAvailability.MALFORMED, failed.trace.availability)
        assertFalse(json.encodeToString(failed.trace).contains("PRIVATE_"))
        assertEquals(TraceAvailability.UNAVAILABLE, ExitTraceReader.read(ExitTraceFormat.ANR_TEXT, 1) {
            object : ByteArrayInputStream(byteArrayOf()) { override fun close() { throw IOException("PRIVATE_CLOSE") } }
        }.trace.availability)
    }

    @Test fun malformedAndWrongProcessNativeStreamsCannotReturnCoordinates() {
        val samples = listOf(byteArrayOf(0), byteArrayOf(0x80.toByte()), ByteArray(11) { 0x80.toByte() }, byteArrayOf(0x0b),
            resource("tombstone.pb").dropLast(1).toByteArray())
        samples.forEach { data ->
            val parsed = NativeTombstoneParser.parse(data.inputStream(), 4242)
            assertEquals(TraceAvailability.MALFORMED, parsed.trace.availability)
            assertTrue(parsed.trace.nativeFrames.isEmpty())
        }
        assertEquals(TraceAvailability.MALFORMED, NativeTombstoneParser.parse(resource("tombstone.pb").inputStream(), 123).trace.availability)
    }

    @Test fun nativeCoordinatesRejectUnownedNamesNonHexBuildIdsAndUnsafeUnsignedOffsets() {
        val invalid = listOf(nativeFrame("private.so", "0123456789abcdef", 1uL), nativeFrame("https://private.example/libxul.so", "0123456789abcdef", 1uL),
            nativeFrame("libxul.so", "PRIVATE_BUILD_ID", 1uL), nativeFrame("libxul.so", "0123456789abcdef", 9_007_199_254_740_992uL),
            nativeFrame("libxul.so", "0123456789abcdef", ULong.MAX_VALUE))
        val parsed = NativeTombstoneParser.parse(tombstone(invalid).inputStream(), 42)
        assertTrue(parsed.trace.nativeFrames.isEmpty())
        assertEquals(TraceAvailability.PARTIAL, parsed.trace.availability)
        val unsafe = ExitTrace(ExitTraceFormat.NATIVE_TOMBSTONE, TraceAvailability.PARTIAL,
            listOf(NativeCodeFrame("/data/PRIVATE/libxul.so", "0123456789abcdef", 1), NativeCodeFrame("libxul.so", "PRIVATE_ID", 2),
                NativeCodeFrame("libxul.so", "0123456789abcdef", -1), NativeCodeFrame("libxul.so", "0123456789abcdef", Long.MAX_VALUE)))
        val wire = ReportWire.reportText(saved(TraceProjection(unsafe)))
        assertFalse(wire.contains("PRIVATE")); assertFalse(wire.contains("imageOffset"))
    }

    @Test fun limitsStopHugeUnknownProtoPayloadsAndExcessFramesWithoutAllocatingTheirContent() {
        val prefix = tombstone(listOf(nativeFrame("libxul.so", "0123456789abcdef", 0uL))) + varint((99 shl 3 or 2).toULong()) + varint(2_000_000uL)
        var reads = 0
        val input = object : ByteArrayInputStream(prefix) {
            override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, len).also { if (it > 0) reads += it }
        }
        val limited = NativeTombstoneParser.parse(input, 42)
        assertEquals(TraceAvailability.PARTIAL, limited.trace.availability)
        assertEquals(1, limited.trace.nativeFrames.size)
        assertTrue(reads <= 4096)
        val many = NativeTombstoneParser.parse(tombstone(List(600) { nativeFrame("libxul.so", "0123456789abcdef", it.toULong()) }).inputStream(), 42)
        assertEquals(512, many.trace.nativeFrames.size)
        assertEquals(TraceAvailability.PARTIAL, many.trace.availability)
        val text = "----- pid 42 at fixture -----\n\"PRIVATE\" prio=5 tid=1 Native\n  | sysTid=42 nice=0\n" +
            "  at dev.yab.Engine.read(Engine.kt:1)\n".repeat(600)
        val anr = AnrTraceParser.parse(text.byteInputStream(), 42)
        assertEquals(512, anr.frames.size); assertEquals(TraceAvailability.PARTIAL, anr.trace.availability)
    }

    @Test fun overlongAnrLineCannotSmuggleItsSuffixIntoAFrame() {
        val text = "----- pid 42 at fixture -----\n\"PRIVATE\" prio=5 tid=1 Native\n  | sysTid=42 nice=0\n" +
            "PRIVATE".repeat(1000) + "  at dev.yab.Secret.run(Source.kt:7)\n"
        val parsed = AnrTraceParser.parse(text.byteInputStream(), 42)
        assertEquals(TraceAvailability.PARTIAL, parsed.trace.availability); assertTrue(parsed.frames.isEmpty())
    }

    @Test fun onlyTheExactInstalledManifestProcessesAreOwnedAndNamesAreNotInWire() {
        val declared = setOf("dev.yab.android:tab0", "dev.yab.android:gpu")
        assertTrue(ReportExitOwnership.owns("dev.yab.android", "dev.yab.android", declared))
        assertTrue(ReportExitOwnership.owns("dev.yab.android", "dev.yab.android:tab0", declared))
        for (name in listOf("dev.yab.android:tab99", "dev.yab.android.evil:tab0", "other.app", null)) assertFalse(ReportExitOwnership.owns("dev.yab.android", name, declared))
        assertFalse(ReportExitOwnership.owns("dev.yab.android", "dev.yab.android:tab0", emptySet()))
        assertFalse(ReportWire.reportText(saved(NativeTombstoneParser.parse(resource("tombstone.pb").inputStream(), 4242))).contains("process"))
    }

    @Test fun legacySavedJvmReportsRemainReadableWithoutTraceAndConsentStillGatesNativeProjection(): Unit = runTest {
        val legacy = """{"key":"old","version":"1","build":"1","os":"Android","device":"Fixture","reason":"Failure","frames":["dev.yab.Engine.read:8"],"at":1}"""
        val old = json.decodeFromString<SavedCrash>(legacy)
        assertNull(old.trace); assertFalse(ReportWire.reportText(old).contains("androidTrace"))
        val store = object : ReportStore {
            var value = ReportSnapshot(since = 1, dailyActivity = false)
            override suspend fun load() = value
            override suspend fun save(snapshot: ReportSnapshot) { value = snapshot }
        }
        val requests = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { requests.add(it); true }, ReportMetadata("1", "1", "Android", "Fixture", "dev.yab.android"), backgroundScope)
        runCurrent(); controller.received(listOf(saved(NativeTombstoneParser.parse(resource("tombstone.pb").inputStream(), 4242))))
        controller.foregrounded(false); runCurrent(); assertTrue(requests.isEmpty())
        controller.setPresentationAllowed(true); runCurrent()
        assertTrue(requests.isEmpty()); controller.answer(requireNotNull(controller.state.value.question).token, true); runCurrent()
        assertEquals(listOf("api/crash"), requests.map { it.path }); assertTrue(store.value.pending.isEmpty())
        controller.close()
    }

    private fun varint(value: ULong): ByteArray {
        var n = value; val bytes = ArrayList<Byte>()
        while (n >= 128uL) { bytes.add(((n and 127uL) or 128uL).toByte()); n = n shr 7 }
        bytes.add(n.toByte()); return bytes.toByteArray()
    }
    private fun number(field: Int, value: ULong) = varint((field shl 3).toULong()) + varint(value)
    private fun blob(field: Int, value: ByteArray) = varint((field shl 3 or 2).toULong()) + varint(value.size.toULong()) + value
    private fun nativeFrame(name: String, build: String, offset: ULong) = number(1, offset) + blob(6, name.toByteArray()) + blob(8, build.toByteArray())
    private fun tombstone(frames: List<ByteArray>): ByteArray = number(5, 42uL) + number(6, 43uL) +
        blob(16, number(1, 43uL) + blob(2, frames.fold(number(1, 43uL)) { result, frame -> result + blob(4, frame) }))
}

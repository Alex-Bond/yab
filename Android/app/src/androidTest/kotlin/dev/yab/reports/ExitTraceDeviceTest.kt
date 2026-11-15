package dev.yab.reports

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.ResultReceiver
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic privacy fixture plus an independently acquired, real OS native exit from a debug-only child. */
@RunWith(AndroidJUnit4::class)
class ExitTraceDeviceTest {
    @Test(timeout = 150_000)
    fun realOwnedNativeExitProducesCodeCoordinatesAndNeverPersistsItsRawTombstone(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true") { "This self-crash proof requires the owned emulator" }
        check(Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish") { "This self-crash proof requires an Android emulator" }
        check(Build.VERSION.SDK_INT >= 31) { "Native ApplicationExitInfo streams require API 31" }
        assertNull(AndroidReports.configuredSite(context))
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val collector = AndroidReports(context, scope)
        val folder = File(context.cacheDir, "real-exit-trace-${UUID.randomUUID()}")
        val scenario = ActivityScenario.launch(EngineTestActivity::class.java)
        var controller: ReportsController? = null
        val service = Intent(context, NativeTraceProofService::class.java).setAction(NativeTraceProofService.ACTION)
        try {
            val expectedProcess = context.packageName + NativeTraceProofService.PROCESS_SUFFIX
            val ownService = context.packageManager.getServiceInfo(requireNotNull(service.component), 0)
            assertTrue("Debug proof service must be non-exported and scoped to its own process", !ownService.exported && ownService.processName == expectedProcess)
            val declared = AndroidReports.ownedExitProcesses(context)
            assertTrue(declared.contains(expectedProcess))
            assertTrue(ReportExitOwnership.owns(context.packageName, expectedProcess, declared))
            val armed = CompletableDeferred<Pair<Int, Long>>()
            val receiver = object : ResultReceiver(Handler(Looper.getMainLooper())) {
                override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                    if (resultCode == NativeTraceProofService.ARMED && resultData != null) armed.complete(
                        resultData.getInt(NativeTraceProofService.PID) to resultData.getLong(NativeTraceProofService.STARTED_AT))
                }
            }
            val beforeStart = System.currentTimeMillis()
            // The anonymous receiver belongs to the instrumentation APK, which
            // the app-only child cannot load. Send its framework Binder proxy.
            val childReceiver = frameworkReceiver(receiver)
            scenario.onActivity { activity ->
                check(activity.lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED))
                checkNotNull(activity.startService(service.putExtra(NativeTraceProofService.RECEIVER, childReceiver)))
            }
            val (pid, childStarted) = withTimeout(15_000) { armed.await() }
            check(pid > 0 && pid != Process.myPid()) { "The owned child did not supply its separate pid" }
            check(childStarted >= beforeStart) { "The owned child receipt predates this proof" }
            val manager = requireNotNull(context.getSystemService(ActivityManager::class.java))
            val deadline = SystemClock.elapsedRealtime() + 90_000
            var actual: ApplicationExitInfo? = null
            var projected: TraceProjection? = null
            var availability = TraceAvailability.UNAVAILABLE
            while (SystemClock.elapsedRealtime() < deadline) {
                val exits = withContext(Dispatchers.IO) {
                    try { manager.getHistoricalProcessExitReasons(context.packageName, pid, 5) }
                    catch (_: Exception) { throw AssertionError("Android refused this package's own exit-info lookup") }
                }
                val exit = exits.firstOrNull { it.pid == pid && it.processName == expectedProcess &&
                    it.timestamp >= childStarted && it.reason == ApplicationExitInfo.REASON_CRASH_NATIVE }
                if (exit != null) {
                    val candidate = withContext(Dispatchers.IO) {
                        ExitTraceReader.read(ExitTraceFormat.NATIVE_TOMBSTONE, pid) { exit.traceInputStream }
                    }
                    availability = candidate.trace.availability
                    if (candidate.trace.nativeFrames.isNotEmpty() && availability in setOf(TraceAvailability.AVAILABLE, TraceAvailability.PARTIAL)) {
                        actual = exit; projected = candidate; break
                    }
                }
                delay(250)
            }
            val exit = checkNotNull(actual) { "Android did not expose this child's native trace with safe coordinates ($availability)" }
            val projection = checkNotNull(projected)
            assertEquals(ApplicationExitInfo.REASON_CRASH_NATIVE, exit.reason)
            assertTrue(ReportExitOwnership.owns(context.packageName, exit.processName, declared))
            val observed = checkNotNull(ReportExitCounts.observation(exit.timestamp, exit.pid, exit.reason, exit.importance, exit.processName))
            assertEquals(5, observed.reason)
            assertTrue("The numeric projection must retain its original OS event time", exit.timestamp == observed.at)
            val observedDay = java.time.Instant.ofEpochMilli(exit.timestamp).atZone(java.time.ZoneOffset.UTC).toLocalDate().toString()
            assertTrue(projection.trace.nativeFrames.isNotEmpty())
            assertTrue(projection.trace.nativeFrames.all(ReportCode::native))
            val report = SavedCrash("real-native-proof", "0.1.0", "3", "Android fixture", "Fixture", "ANDROID_NATIVE_CRASH",
                projection.frames, exit.timestamp, CrashSource.ANDROID_EXIT, projection.trace)
            val serialized = Json.encodeToString(report) + ReportWire.reportText(report)
            for (marker in listOf(NativeTraceProofService.CANARY, expectedProcess, "processName", "threadName", "registers", "memory", "/apex/", "/data/", "function_name")) {
                assertFalse("Forbidden diagnostic material reached the code projection", serialized.contains(marker))
            }
            val store = FileReportStore(File(folder, "consent.json"))
            store.save(ReportSnapshot(since = 1, dailyActivity = false))
            val posted = mutableListOf<ReportRequest>()
            val active = ReportsController(store, ReportTransport { posted.add(it); true }, AndroidReports.metadata(context), scope).also { controller = it }
            active.received(listOf(report), listOf(observed)); active.foregrounded(false)
            delay(100); assertTrue(posted.isEmpty())
            assertFalse(File(folder, "consent.json").readText().contains(NativeTraceProofService.CANARY))
            active.setPresentationAllowed(true)
            withTimeout(10_000) { while (active.state.value.question == null) delay(25) }
            assertTrue(posted.isEmpty())
            active.answer(requireNotNull(active.state.value.question).token, true)
            withTimeout(10_000) { while (store.load().pending.isNotEmpty()) delay(25) }
            assertEquals(listOf("api/crash"), posted.map { it.path })
            val request = posted.single()
            assertFalse(request.fields.containsKey("observedExitCounts"))
            val body = Json.parseToJsonElement(request.fields.getValue("report").jsonPrimitive.content.substringAfter('\n')).jsonObject
            val counts = body.getValue("observedExitCounts").jsonObject
            assertEquals(1, counts.getValue("version").jsonPrimitive.int)
            assertEquals("observed", counts.getValue("coverage").jsonPrimitive.content)
            val days = counts.getValue("days").jsonArray
            assertEquals(1, days.size); assertEquals(observedDay, days.single().jsonObject.getValue("day").jsonPrimitive.content)
            val numbers = days.single().jsonObject.getValue("counts").jsonArray.single().jsonObject
            assertEquals(5, numbers.getValue("reason").jsonPrimitive.int)
            assertEquals(1, numbers.getValue("count").jsonPrimitive.int)
            for (marker in listOf(observed.id, exit.timestamp.toString(), expectedProcess, NativeTraceProofService.CANARY, "pid", "processName", "hangTime")) {
                assertFalse("Only aggregated numeric exit metadata may reach the report", counts.toString().contains(marker))
            }
            assertTrue(store.load().exitCounts.pending.isEmpty())
            assertTrue(store.load().exitCounts.allowed.isEmpty())
            assertTrue(observed.id in store.load().exitCounts.seen)
            assertSame(previousHandler, Thread.getDefaultUncaughtExceptionHandler())
        } finally {
            controller?.close(); collector.close(); scope.cancel()
            context.stopService(service); scenario.close()
            folder.listFiles()?.forEach { it.delete() }; folder.delete()
        }
    }

    @Test(timeout = 45_000)
    fun nativeProjectionCrossesAndroidFdAndDurableConsentWithoutEnablingProductionCollectors(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertNull(AndroidReports.configuredSite(context))
        val handler = Thread.getDefaultUncaughtExceptionHandler()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val collector = AndroidReports(context, scope)
        val folder = File(context.cacheDir, "exit-trace-${UUID.randomUUID()}")
        var controller: ReportsController? = null
        try {
            assertSame(handler, Thread.getDefaultUncaughtExceptionHandler())
            val processes = AndroidReports.ownedExitProcesses(context)
            val children = processes.filter { it.startsWith(context.packageName + ":") }
            assertTrue("Installed pinned Gecko manifest must declare its child processes", children.isNotEmpty())
            children.forEach { assertTrue(ReportExitOwnership.owns(context.packageName, it, processes)) }
            assertFalse(ReportExitOwnership.owns(context.packageName, context.packageName + ":not-declared", processes))
            val fixture = instrumentation.context.assets.open("reports/tombstone.pb").use { it.readBytes() }
            assertEquals("ef6d69539ec5a44772f4f45053d60a4ea06d60f23a317feb3c50bd772e60f516",
                MessageDigest.getInstance("SHA-256").digest(fixture).joinToString("") { "%02x".format(it.toInt() and 255) })
            val pipe = ParcelFileDescriptor.createPipe()
            ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { it.write(fixture) }
            val projection = ExitTraceReader.read(ExitTraceFormat.NATIVE_TOMBSTONE, 4242) { ParcelFileDescriptor.AutoCloseInputStream(pipe[0]) }
            assertEquals(TraceAvailability.AVAILABLE, projection.trace.availability)
            assertEquals(2, projection.trace.nativeFrames.size)
            val store = FileReportStore(File(folder, "consent.json"))
            store.save(ReportSnapshot(since = 1, dailyActivity = false))
            val posted = mutableListOf<ReportRequest>()
            val active = ReportsController(store, ReportTransport { posted.add(it); true }, AndroidReports.metadata(context), scope).also { controller = it }
            val report = SavedCrash("synthetic-native", "0.1.0", "3", "Android fixture", "Fixture", "ANDROID_NATIVE_CRASH", projection.frames,
                2, CrashSource.ANDROID_EXIT, projection.trace)
            active.received(listOf(report)); active.foregrounded(false)
            delay(100)
            assertTrue(posted.isEmpty())
            val disk = File(folder, "consent.json").readText()
            for (marker in listOf("PRIVATE_", "private.example", "/data/", "user@example", "threadName", "registers", "memory")) assertFalse(marker, disk.contains(marker))
            active.setPresentationAllowed(true)
            val deadline = SystemClock.elapsedRealtime() + 10_000
            while (active.state.value.question == null) { check(SystemClock.elapsedRealtime() < deadline); delay(25) }
            assertTrue(posted.isEmpty())
            active.answer(requireNotNull(active.state.value.question).token, true)
            while (store.load().pending.isNotEmpty()) { check(SystemClock.elapsedRealtime() < deadline); delay(25) }
            assertEquals(listOf("api/crash"), posted.map { it.path })
            assertTrue(posted.single().fields.toString().contains("imageOffset"))
            assertSame(handler, Thread.getDefaultUncaughtExceptionHandler())
        } finally {
            controller?.close(); collector.close(); scope.cancel()
            folder.listFiles()?.forEach { it.delete() }; folder.delete()
        }
    }

    private fun frameworkReceiver(receiver: ResultReceiver): ResultReceiver {
        val parcel = Parcel.obtain()
        return try {
            receiver.writeToParcel(parcel, 0)
            parcel.setDataPosition(0)
            ResultReceiver.CREATOR.createFromParcel(parcel).also {
                assertEquals("Only the framework receiver may cross into the app-only child", ResultReceiver::class.java, it.javaClass)
            }
        } finally { parcel.recycle() }
    }
}

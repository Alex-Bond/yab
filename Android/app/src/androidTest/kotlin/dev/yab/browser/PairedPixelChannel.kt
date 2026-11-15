package dev.yab.browser

import android.os.SystemClock
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.json.JSONObject

/** Test-only, exact nonce protocol. It never accepts app data, code, URLs or input coordinates.
 * The supplied guard performs the original UI-thread activity/view/source/scales checks and
 * exact owned accessibility root check. Never call its blocking guard from Main. */
internal class PairedPixelChannel(private val nonce: String, private val current: () -> Boolean) {
    init { check(nonce.matches(Regex("[a-f0-9]{32}"))) }
    private enum class Phase(val wire: String) {
        CALIBRATION("calibration"), TRANSITION("transition"), READY("ready"), RECORDING("recording"),
        STOP_READY("stop-ready"), STOPPED("stopped"), ABORTED("aborted")
    }
    private val phase = AtomicReference(Phase.CALIBRATION)
    private val calibrated = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val stopped = AtomicBoolean(false)
    private val closing = AtomicBoolean(false)
    private val samples = AtomicInteger(0)
    private val guardsStarted = AtomicInteger(0)
    private val guardsCompleted = AtomicInteger(0)
    private val responses = AtomicInteger(0)
    private val began = SystemClock.elapsedRealtime()
    private val active = AtomicReference<Socket?>(null)
    private val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).apply { soTimeout = 250 }
    val port: Int get() = server.localPort
    private val worker = Thread({ serve() }, "OwnedPairedPixels").apply { isDaemon = true; start() }

    private fun serve() {
        try {
            while (!closing.get() && SystemClock.elapsedRealtime() - began < 60_000 && samples.get() < 5000) {
                val connection = try { server.accept() } catch (_: SocketTimeoutException) { continue }
                active.set(connection)
                try { connection.use { exchange(it) } } catch (_: Exception) { /* Fixed refusal, no raw request/error output. */ }
                finally { active.compareAndSet(connection, null) }
            }
        } catch (_: Exception) { /* Closing the exact original server ends accept. */ }
        finally { if (phase.get() != Phase.STOPPED) phase.set(Phase.ABORTED) }
    }

    private fun exchange(socket: Socket) {
        socket.soTimeout = 800
        val input = socket.getInputStream()
        val bytes = ArrayList<Byte>(128)
        val deadline = SystemClock.elapsedRealtime() + 1200
        while (true) {
            check(SystemClock.elapsedRealtime() < deadline && bytes.size < 1024 && !closing.get())
            val value = input.read()
            check(value >= 0)
            if (value == 10) break
            bytes += value.toByte()
        }
        val request = JSONObject(bytes.toByteArray().toString(Charsets.UTF_8))
        val keys = request.keys().asSequence().toSet()
        check(keys == setOf("nonce", "scenario", "operation") && request.opt("nonce") is String &&
            request.opt("scenario") is String && request.opt("operation") is String && request.optString("nonce") == nonce &&
            request.optString("scenario") == "pairEyesClose")
        val operation = request.optString("operation")
        check(operation in setOf("STATUS", "CALIBRATED", "START", "STOPPED", "ABORT"))
        val before = guardedCurrent()
        val expected = phase.get()
        val allowed = before && when (operation) {
            "STATUS" -> true
            "CALIBRATED" -> expected == Phase.CALIBRATION && !calibrated.get()
            "START" -> expected == Phase.READY && !started.get()
            "STOPPED" -> expected == Phase.STOP_READY && !stopped.get()
            else -> expected != Phase.STOPPED && expected != Phase.ABORTED
        }
        // Publish command authority only after both fresh guard projections.
        val owner = allowed && guardedCurrent()
        val accepted = owner && phase.get() == expected && when (operation) {
            "STATUS" -> true
            "CALIBRATED" -> if (phase.compareAndSet(Phase.CALIBRATION, Phase.TRANSITION)) { calibrated.set(true); true } else false
            "START" -> if (phase.compareAndSet(Phase.READY, Phase.RECORDING)) { started.set(true); true } else false
            "STOPPED" -> phase.compareAndSet(Phase.STOP_READY, Phase.STOPPED)
            else -> phase.compareAndSet(expected, Phase.ABORTED)
        }
        val response = JSONObject().put("schema", 1).put("nonce", nonce).put("scenario", "pairEyesClose")
            .put("phase", phase.get().wire).put("sample", samples.incrementAndGet()).put("accepted", accepted)
            .put("current", owner).put("animationsEnabled", owner).put("viewportPx", JSONArray(listOf(1206, 2622)))
            .toString().toByteArray(Charsets.UTF_8)
        check(response.size <= 2047 && !closing.get())
        socket.getOutputStream().apply { write(response); write(10); flush() }
        responses.incrementAndGet()
        if (accepted && operation == "STOPPED") stopped.set(true) // ACK is on the wire before Activity teardown.
    }

    private fun guardedCurrent(): Boolean {
        guardsStarted.incrementAndGet()
        return try { runCatching(current).getOrDefault(false) }
        finally { guardsCompleted.incrementAndGet() }
    }

    /** Fixed counters only. Reading this snapshot grants no protocol authority. */
    fun diagnostics(): JSONObject = JSONObject().put("phase", phase.get().wire)
        .put("samples", samples.get()).put("guardsStarted", guardsStarted.get())
        .put("guardsCompleted", guardsCompleted.get()).put("responses", responses.get())
        .put("workerAlive", worker.isAlive).put("closing", closing.get())

    suspend fun awaitCalibrated() = await { calibrated.get() }
    suspend fun awaitStarted() = await { started.get() && phase.get() == Phase.RECORDING }
    suspend fun awaitStopped() = await { stopped.get() && phase.get() == Phase.STOPPED }
    private suspend fun await(accepted: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 15_000
        while (!accepted()) {
            check(!closing.get() && phase.get() != Phase.ABORTED && worker.isAlive && SystemClock.elapsedRealtime() < deadline)
            delay(8)
        }
    }
    fun ready() { check(calibrated.get() && phase.compareAndSet(Phase.TRANSITION, Phase.READY)) }
    fun stopReady() { check(started.get() && phase.compareAndSet(Phase.RECORDING, Phase.STOP_READY)) }
    fun finish(): Boolean {
        closing.set(true)
        runCatching { server.close() }
        active.getAndSet(null)?.let { runCatching { it.close() } }
        worker.interrupt()
        worker.join(1500)
        return !worker.isAlive
    }
}

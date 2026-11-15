package dev.yab.reports

import android.app.Application
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.os.ResultReceiver
import dev.yab.android.BuildConfig
import java.util.concurrent.CountDownLatch

/** Debug-only, non-exported self-crash fixture. It never accepts a pid or signals another process. */
class NativeTraceProofService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val canaryLifetime = CountDownLatch(1)
    private var signal: Runnable? = null
    private var armed = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!BuildConfig.DEBUG || Application.getProcessName() != packageName + PROCESS_SUFFIX || intent == null || intent.action != ACTION) {
            stopSelf(startId); return START_NOT_STICKY
        }
        val receiver = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(RECEIVER, ResultReceiver::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableExtra<ResultReceiver>(RECEIVER)
        if (receiver == null || armed) { if (!armed) stopSelf(startId); return START_NOT_STICKY }
        armed = true
        Thread({ canaryLifetime.await() }, CANARY).apply { isDaemon = true; start() }
        val ownPid = Process.myPid()
        receiver.send(ARMED, Bundle().apply { putInt(PID, ownPid); putLong(STARTED_AT, System.currentTimeMillis()) })
        signal = Runnable {
            // SIGSEGV lets Android's normal debuggerd produce its tombstone. No SIGKILL/retry fallback.
            if (Process.myPid() == ownPid) Process.sendSignal(ownPid, 11)
        }.also { handler.postDelayed(it, 1_000) }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        signal?.let(handler::removeCallbacks)
        signal = null; canaryLifetime.countDown()
        super.onDestroy()
    }

    companion object {
        const val PROCESS_SUFFIX = ":nativeTraceProof"
        const val ACTION = "dev.yab.reports.NATIVE_TRACE_PROOF"
        const val RECEIVER = "receiver"
        const val PID = "pid"
        const val STARTED_AT = "startedAt"
        const val ARMED = 1
        const val CANARY = "P03_PRIVATE_TAG" // Fits the Linux thread-name limit without truncation.
    }
}

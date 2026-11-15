package dev.yab.sync

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.SystemClock
import android.util.AtomicFile
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import dev.yab.android.BuildConfig
import dev.yab.android.YabApplication
import dev.yab.core.crypto.Seal
import dev.yab.core.sync.Clock
import dev.yab.notifications.AndroidNotificationSyncPort
import dev.yab.notifications.NotificationPolicy
import dev.yab.notifications.PushNotifications
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit

/** External acceptance only. Real Google delivery is required; missing arguments fail.
 * This warm, disposable Google APIs emulator is not physical Doze/cold-start proof. */
@RunWith(AndroidJUnit4::class)
class FcmDeviceTest {
    @Test(timeout = 720_000)
    fun realGoogleDeliveryWakesSealedJournalDeduplicatesAndWithdrawsApproval() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        check(BuildConfig.DEBUG && args.getString("requireFcmProof") == "true" && args.getString("ownedEmulator") == "true") { "Use fcm-device-proof.py" }
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        check(target.packageName == PACKAGE)
        val run = checkNotNull(args.getString("fcmRun")).also { require(it.matches(Regex("[a-f0-9]{32}"))) }
        val job = checkNotNull(args.getString("sourceJob")).also { require(it.matches(Regex("[a-f0-9]{16}"))) }
        val snapshot = checkNotNull(args.getString("sourceSnapshot")).also { require(it.matches(Regex("[a-f0-9]{40}"))) }
        require(args.getString("firebaseConfigSHA256") == CONFIG_SHA)
        val url = checkNotNull(args.getString("syncBackendUrl")).trimEnd('/')
        val endpoint = url.toHttpUrl()
        require(endpoint.scheme == "http" && endpoint.host == "127.0.0.1" && endpoint.port > 0 && endpoint.encodedPath == "/" && endpoint.username.isEmpty() && endpoint.password.isEmpty())
        check(SyncIdentityStore(target).load() == null) { "FCM proof requires empty app identity in its fresh owned emulator" }
        val app = target.applicationContext as YabApplication
        app.sync.awaitClosedForTests()
        val firebase = FirebaseApp.getInstance().options
        check(firebase.applicationId == APP && firebase.projectId == PROJECT && firebase.gcmSenderId == NUMBER)
        check(PushNotifications.allowed(target)) { "Grant notification permission only on the owned fixture" }
        val folder = File(target.filesDir, "fcm-proof/$run").apply { check(mkdirs()) }
        val outbox = AtomicFile(File(folder, "outbox.json"))
        val receiptsFile = AtomicFile(File(folder, "receipts.json"))
        val receipts = mutableListOf<JsonObject>()
        fun atomic(file: AtomicFile, text: String) {
            val stream = file.startWrite()
            try { stream.write(text.toByteArray()); file.finishWrite(stream) }
            catch (failure: Throwable) { file.failWrite(stream); throw failure }
        }
        fun saveReceipts(complete: Boolean = false) = atomic(receiptsFile, buildJsonObject {
            put("version", 1); put("run", run); put("job", job); put("snapshot", snapshot); put("complete", complete)
            put("receipts", JsonArray(receipts)); put("rawLogcatCaptured", false)
        }.toString())
        saveReceipts()
        val http = OkHttpClient.Builder().callTimeout(20, TimeUnit.SECONDS).followRedirects(false).build()
        val seal = Seal.make()
        val bridge = AndroidSyncBridge(target, url, allowInsecureForTests = true)
        val work = WorkManager.getInstance(target)
        val notifications = target.getSystemService(NotificationManager::class.java)
        val prefs = target.getSharedPreferences("push", Context.MODE_PRIVATE)
        fun infos(name: String) = work.getWorkInfosForUniqueWork(name).get(10, TimeUnit.SECONDS)
        fun notification(id: String) = notifications.activeNotifications.singleOrNull { it.tag == "approval:$id" }
        suspend fun await(message: String, condition: () -> Boolean) {
            val until = SystemClock.elapsedRealtime() + 120_000
            while (SystemClock.elapsedRealtime() < until) { if (condition()) return; delay(100) }
            error("FCM proof did not observe $message")
        }
        suspend fun pause() { bridge.pause(); await("stopped local socket") { bridge.ui.value.phase == "off" } }
        try {
            SyncDeviceTest.MacPeer(url, seal, http).use { mac ->
                mac.push(listOf(mac.record("commandcap", mac.device) {
                    put("device", mac.device); put("platform", "macos"); put("androidSync", 1); put("open", 1); put("chatAgent", 1)
                }))
                bridge.joinRecovery(seal.recovery)
                await("local Worker account and genuine Mac capability") {
                    bridge.ui.value.phase == "live" && bridge.ui.value.account == seal.account && bridge.connection.value.macs.any { it.id == mac.device }
                }
                val priorRegistration = infos("fcm-token-registration").map { it.id }.toSet()
                PushNotifications.initialize(target, AndroidNotificationSyncPort(bridge))
                check(PushNotifications.configured)
                val token = withTimeout(120_000) { suspendCancellableCoroutine<String> { wait ->
                    FirebaseMessaging.getInstance().token.addOnSuccessListener { if (wait.isActive) wait.resumeWith(Result.success(it)) }
                        .addOnFailureListener { if (wait.isActive) wait.resumeWith(Result.failure(IllegalStateException("Firebase token acquisition failed"))) }
                } }
                require(token.length in 16..4096 && token.all { it.code in 33..126 })
                await("real WorkManager registration accepted by production Worker") {
                    prefs.getString("pendingToken", null) == token && infos("fcm-token-registration").any { it.id !in priorRegistration && it.state == WorkInfo.State.SUCCEEDED }
                }
                val tokenHash = hash(token.toByteArray())
                val android = checkNotNull(bridge.ownDevice)
                val approvalId = UUID.randomUUID().toString()
                val issued = System.currentTimeMillis() / 1000
                val approval = mac.record("assistantapproval", approvalId) { put("body", buildJsonObject {
                    put("id", approvalId); put("account", seal.account); put("mac", mac.device); put("assistant", "claude"); put("session", "fcm-fixture")
                    put("tab", "chat:fcm-fixture"); put("permit", "mail.read"); put("title", "Yab FCM fixture")
                    put("lines", buildJsonArray { add("Fixture question") }); put("issued", issued); put("expires", issued + 600)
                }.toString()) }
                val detail = mac.record("assistantdetail", approvalId) { put("body", buildJsonObject { put("id", approvalId); put("text", "Fixture question") }.toString()) }
                val sealedName = seal.name(approval.key)
                val sealedBlob = Base64.getEncoder().encodeToString(seal.seal(approval))
                require(sealedBlob.length <= 3000)
                suspend fun delivery(sequence: Int, kind: String, checkDelivery: () -> Boolean) {
                    val unique = "fcm-${if (kind == "sync") "sync" else approvalId}"
                    val before = infos(unique).map { it.id }.toSet()
                    val raw = buildJsonObject {
                        put("version", 1); put("run", run); put("job", job); put("snapshot", snapshot); put("sequence", sequence); put("kind", kind)
                        put("project", PROJECT); put("package", PACKAGE); put("configurationSHA256", CONFIG_SHA)
                        put("target", buildJsonObject { put("device", android); put("token", token); put("env", "fcm"); put("topic", PACKAGE) })
                        if (kind != "sync") put("approval", approvalId)
                        if (kind == "approval") put("sealed", buildJsonObject { put("name", sealedName); put("blob", sealedBlob) })
                    }.toString()
                    atomic(outbox, raw)
                    await("Google stage $sequence through production service/WorkManager") {
                        infos(unique).any { it.id !in before && it.state == WorkInfo.State.SUCCEEDED } && checkDelivery()
                    }
                    receipts += buildJsonObject {
                        put("sequence", sequence); put("kind", kind); put("outboxSHA256", hash(raw.toByteArray())); put("tokenSHA256", tokenHash)
                        put("observed", true); put("productionWorkManagerSucceeded", true)
                    }
                    outbox.delete(); saveReceipts()
                }
                pause()
                val marker = mac.record("space", UUID.randomUUID().toString()) { put("name", "FCM fixture") }
                mac.push(listOf(marker))
                assertTrue(bridge.accountRecords.value.records.none { it.key == marker.key })
                delivery(1, "sync") { bridge.accountRecords.value.records.any { it == marker } }
                await("push-only socket stopped after sync wake") { bridge.ui.value.phase == "off" }
                mac.push(listOf(approval, detail))
                val ledger = NotificationPolicy.ledgerKey(seal.account, approvalId)
                delivery(2, "approval") {
                    notification(approvalId) != null && prefs.getBoolean("validated.$ledger", false) && bridge.approvals.value.any { it.id == approvalId }
                }
                val first = checkNotNull(notification(approvalId))
                assertEquals("Yab FCM fixture", first.notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
                val public = checkNotNull(first.notification.publicVersion)
                assertEquals("Yab", public.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
                assertEquals("Needs your answer", public.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString())
                assertEquals(Notification.VISIBILITY_PRIVATE, first.notification.visibility)
                val announced = prefs.getLong("announced.$ledger", 0); check(announced > 0)
                await("push-only socket stopped before duplicate") { bridge.ui.value.phase == "off" }
                delivery(3, "approval") { notification(approvalId)?.postTime == first.postTime && prefs.getLong("announced.$ledger", 0) == announced }
                await("push-only socket stopped before withdrawal") { bridge.ui.value.phase == "off" }
                mac.push(listOf(approval.removed(Clock(mac.device, approval.stamps.getValue("body")).tick())))
                delivery(4, "withdraw") { notification(approvalId) == null && bridge.approvals.value.none { it.id == approvalId } }
                saveReceipts(complete = true)
            }
        } finally {
            outbox.delete()
            withContext(NonCancellable) {
                runCatching { bridge.forgetPushToken() }
                bridge.awaitClosedForTests()
            }
            prefs.edit().clear().commit()
            SyncIdentityStore(target).forget()
            http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll()
        }
    }
    companion object {
        private const val PROJECT = "yab-android-test-261022-01a164"
        private const val NUMBER = "371464049690"
        private const val APP = "1:371464049690:android:7524764826ca176ea0eda3"
        private const val PACKAGE = "dev.yab.android.dev"
        private const val CONFIG_SHA = "d2bbe5b3f2cd4b0d629a72fdb114790579725c13522338eb0ee2dc2ef20545d3"
        private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}

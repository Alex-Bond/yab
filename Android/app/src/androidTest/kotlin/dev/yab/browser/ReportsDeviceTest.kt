package dev.yab.browser

import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.AndroidAccessibilityPreferences
import dev.yab.browser.ui.BrowserTheme
import dev.yab.reports.*
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real Android file/UI/preferences; outbound report transport is explicitly a local fixture. */
@RunWith(AndroidJUnit4::class)
class ReportsDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 90_000)
    fun savedConsentSurvivesAndroidFileReloadAndQuestionDefersBehindPrivateGate(): Unit = runBlocking {
        val file = File(context.cacheDir, "reports-${UUID.randomUUID()}.json")
        val store = FileReportStore(file)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var controller: ReportsController? = null
        var scenario = ActivityScenario.launch(EngineTestActivity::class.java)
        var originalHost: EngineTestActivity? = null
        val requests = mutableListOf<ReportRequest>()
        try {
            store.save(ReportSnapshot(since = 1, dailyActivity = false))
            val first = ReportsController(store, ReportTransport { false }, AndroidReports.metadata(context), scope).also { controller = it }
            await("saved choices") { !first.state.value.loading }
            first.received(listOf(SavedCrash("owned-crash", "0.1.0", "1", "Android fixture", "Fixture", "FixtureFailure", listOf("dev.yab.Fixture.run:1"), 2)))
            main { first.foregrounded(false) }
            scenario.onActivity { originalHost = it; it.setContent { BrowserTheme(BrowserAppearance.SYSTEM) { Column(Modifier.verticalScroll(rememberScrollState())) { ReportPreferences(first); FeedbackForm(first) }; CrashReportQuestion(first) } } }
            assertNull(first.state.value.question)
            main { first.setPresentationAllowed(true) }
            await("native crash consent question") { node("Share saved crash reports?") != null }
            main { first.setPresentationAllowed(false) }
            await("private gate hides question without declining") { node("Share saved crash reports?") == null }
            assertEquals(1, store.load().pending.size)
            main { first.setPresentationAllowed(true) }
            click("Send")
            await("one-set approval durably saved") { "owned-crash" in store.load().allowed }
            assertFalse(store.load().automaticCrashes)
            main { first.close() }
            // This is a real file/controller relaunch. Retire its original
            // native window too, rather than racing old and new FeedbackForm
            // semantics inside one reused Compose host.
            scenario.close()
            scenario = ActivityScenario.launch(EngineTestActivity::class.java)
            val next = ReportsController(store, ReportTransport { requests.add(it); true }, AndroidReports.metadata(context), scope).also { controller = it }
            await("choices loaded after relaunch") { !next.state.value.loading }
            main { next.foregrounded(true) }
            await("approved report accepted without re-asking") { store.load().pending.isEmpty() }
            assertNull(next.state.value.question)
            assertEquals(listOf("api/crash"), requests.map { it.path })
            scenario.onActivity {
                assertTrue(checkNotNull(originalHost).isDestroyed)
                assertNotSame(originalHost, it)
                it.setContent { BrowserTheme(BrowserAppearance.SYSTEM) { Column(Modifier.verticalScroll(rememberScrollState())) { FeedbackForm(next) } } }
            }
            var originalFeedback: AccessibilityNodeInfo? = null
            await("editable feedback controls") {
                originalFeedback = if (editableNodes().size == 2) labelledEditable("What happened?") else null
                originalFeedback != null
            }
            // Use the original admitted native node once. A second root query
            // can observe the transient IME window instead of this owned form.
            assertTrue(checkNotNull(originalFeedback).performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, android.os.Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "Owned feedback fixture")
            }))
            await("native edit reached the original feedback draft") { next.state.value.draft == "Owned feedback fixture" }
            click("Send Feedback")
            await("feedback accepted") { node("Sent. Thank you.") != null }
            assertEquals("", next.state.value.draft)
            assertEquals("api/feedback", requests.last().path)
            BrowserInstrumentedTest().shot("reports-feedback-consent.png")
        } catch (failure: Throwable) {
            val state = controller?.state?.value
            val saved = runCatching { store.load() }.getOrNull()
            val evidence = org.json.JSONObject().put("loading", state?.loading).put("available", state?.available)
                .put("storageErrorPresent", state?.storageError != null).put("pending", saved?.pending?.size)
                .put("allowed", saved?.allowed?.size).put("requests", requests.size)
                .put("draftMatchesFixture", state?.draft == "Owned feedback fixture")
                .put("emailMatchesFixture", state?.email == "Owned feedback fixture")
                .put("nativeAcceptance", false)
            File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
                .resolve("reports-consent-diagnostics.json").writeText(evidence.toString(2))
            throw failure
        } finally {
            main { controller?.close() }; scenario.close(); scope.cancel(); file.delete(); File(file.path + ".bak").delete()
        }
    }

    @Test(timeout = 45_000)
    fun removeAnimationsUpdatesTheMountedNativePreferenceAndRestoresOnlyItsOwnChange(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        assertEquals("1", shell("getprop ro.kernel.qemu").trim())
        val previous = shell("settings get global animator_duration_scale").trim()
        val observer = main { AndroidAccessibilityPreferences(context) }
        try {
            shell("settings put global animator_duration_scale 1")
            await("live ordinary motion preference") { !observer.state.value.reduceMotion }
            shell("settings put global animator_duration_scale 0")
            await("live system animation preference") { observer.state.value.reduceMotion }
            assertEquals(0, observer.state.value.duration(300))
        } finally {
            if (shell("settings get global animator_duration_scale").trim().toFloatOrNull() == 0f) {
                if (previous == "null") shell("settings delete global animator_duration_scale")
                else if (previous.toFloatOrNull() != null) shell("settings put global animator_duration_scale $previous")
            }
            main { observer.close() }
        }
    }

    private fun node(text: String) = OwnedWebControl.find(text)
    private fun labelledEditable(label: String): AccessibilityNodeInfo? {
        var current = node(label) ?: return null
        repeat(6) {
            if (current.isEditable && current.isEnabled && current.isVisibleToUser && current.packageName?.toString() == context.packageName)
                return current
            current = current.parent ?: return null
        }
        return null
    }
    private fun editableNodes(): List<AccessibilityNodeInfo> {
        if (android.os.Build.VERSION.SDK_INT >= 34) check(instrumentation.uiAutomation.clearCache())
        val result = mutableListOf<AccessibilityNodeInfo>()
        val queue = java.util.ArrayDeque<AccessibilityNodeInfo>()
        instrumentation.uiAutomation.rootInActiveWindow?.let(queue::add)
        var count = 0
        while (queue.isNotEmpty() && count++ < 2000) {
            val item = queue.removeFirst()
            if (item.isEditable && item.isEnabled && item.isVisibleToUser && item.packageName?.toString() == context.packageName) result.add(item)
            repeat(item.childCount) { item.getChild(it)?.let(queue::add) }
        }
        return result
    }
    private suspend fun click(text: String) {
        fun target(): AccessibilityNodeInfo? {
            var current = node(text) ?: return null
            repeat(6) {
                if (current.isClickable) return current.takeIf { it.isEnabled }
                current = current.parent ?: return null
            }
            return null
        }
        var original: AccessibilityNodeInfo? = null
        await("enabled native $text") { original = target(); original != null }
        assertTrue(requireNotNull(original).performAction(AccessibilityNodeInfo.ACTION_CLICK))
    }
    private suspend fun await(label: String, ready: suspend () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 15_000
        while (!ready()) {
            if (SystemClock.elapsedRealtime() >= end) {
                NativeWebControlDiagnostics.capture(label)
                error("Timed out waiting for $label")
            }
            delay(60)
        }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
}

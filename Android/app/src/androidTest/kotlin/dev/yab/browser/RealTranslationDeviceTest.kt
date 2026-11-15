package dev.yab.browser

import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.nativefeatures.MlKitTranslationRuntime
import dev.yab.nativefeatures.PageTranslationController
import dev.yab.nativefeatures.TranslationDialog
import dev.yab.nativefeatures.TranslationPhase
import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Explicit external acceptance: real Google model download and native inference, no translator fixture. */
class RealTranslationDeviceTest {
    @Test(timeout = 900_000)
    fun actualMlKitDownloadDialogTranslatesTheOwnedDocumentAndRestoresOriginal(): Unit = runBlocking {
        val registry = InstrumentationRegistry.getInstrumentation()
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val proof = JSONObject().put("passed", false).put("realMlKit", true)
            .put("ownedLoopbackDocument", true).put("providerFixture", false)
            .put("sourceLanguage", "pt").put("targetLanguage", "en")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var shown by mutableStateOf(false)
        var translator by mutableStateOf<PageTranslationController?>(null)
        val fixture = BrowserInstrumentedTest()
        try {
            OwnedLoopbackSiteSettings.reset()
            TranslationDomTest.TranslationFixture().use { server ->
                fixture.withBrowser(translationMenu = {
                    translator?.takeIf { shown }?.let { TranslationDialog(it, scope) { shown = false } }
                    null
                }) { browser, engine ->
                    val runtime = MlKitTranslationRuntime()
                    val port = engine.translationPort()
                    val controller = PageTranslationController(port, runtime)
                    val observer = scope.launch { controller.observe("en") }
                    try {
                        withContext(Dispatchers.Main.immediate) {
                            translator = controller
                            fixture.ownSpace(browser, "Real translation fixture")
                            browser.openUrl(server.url)
                        }
                        withTimeout(30_000) { port.current.first { it != null } }
                        withTimeout(30_000) { controller.state.first { it.source == "pt" } }
                        val owner = checkNotNull(port.current.value).owner
                        val before = withContext(Dispatchers.Main.immediate) { engine.readText(browser.state.value.tab!!).text }
                        assertTrue(before.contains("Texto original da página"))
                        assertEquals("pt", runtime.identify("Bom dia. Esta página descreve uma entrega e os comentários dos leitores."))
                        assertFalse("Fresh owned AVD unexpectedly has the translation model", runtime.modelsReady("pt", "en"))
                        withContext(Dispatchers.Main.immediate) { controller.translate("en"); shown = true }
                        assertEquals(TranslationPhase.NEED_MODEL, controller.state.value.phase)
                        clickOriginal("Download languages")
                        proof.put("nativeDownloadControlPressed", true)
                        val translated = withTimeout(600_000) {
                            controller.state.first { it.phase in setOf(TranslationPhase.TRANSLATED, TranslationPhase.FAILED) }
                        }
                        assertEquals(translated.error, TranslationPhase.TRANSLATED, translated.phase)
                        assertTrue(runtime.modelsReady("pt", "en"))
                        val actual = runtime.translate("pt", "en", listOf("Olá, mundo.")).single()
                        assertTrue("Native model did not produce English", actual.lowercase().contains("hello"))
                        assertEquals(owner, port.current.value?.owner)
                        val after = withContext(Dispatchers.Main.immediate) { engine.readText(browser.state.value.tab!!).text }
                        assertFalse(after.contains("Texto original da página"))
                        assertTrue(after.lowercase().contains("page"))
                        proof.put("realModelDownloaded", true).put("nativeInferenceVerified", true)
                            .put("actualDocumentTranslated", true)
                        fixture.shot("real-mlkit-translated-document.png")
                        clickOriginal("Show original")
                        withTimeout(15_000) { controller.state.first { it.phase == TranslationPhase.ORIGINAL } }
                        assertEquals(owner, port.current.value?.owner)
                        val restored = withContext(Dispatchers.Main.immediate) { engine.readText(browser.state.value.tab!!).text }
                        assertEquals(before, restored)
                        proof.put("nativeOriginalControlPressed", true).put("exactOriginalTextRestored", true).put("passed", true)
                    } finally {
                        withContext(NonCancellable + Dispatchers.Main.immediate) { shown = false; observer.cancelAndJoin() }
                    }
                }
            }
        } finally {
            scope.cancel()
            val folder = File(registry.targetContext.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
            File(folder, "real-translation-proof.json").writeText(proof.toString(2))
        }
    }

    private suspend fun clickOriginal(label: String) {
        var original: AccessibilityNodeInfo? = null
        val deadline = SystemClock.elapsedRealtime() + 15_000
        while (original == null) {
            var node = OwnedWebControl.find(label)
            repeat(6) {
                val current = node ?: return@repeat
                if (original == null && current.isClickable && current.isEnabled && current.isVisibleToUser) original = current
                node = current.parent
            }
            check(SystemClock.elapsedRealtime() < deadline) { "Original native $label control was not ready" }
            if (original == null) delay(60)
        }
        assertTrue(checkNotNull(original).performAction(AccessibilityNodeInfo.ACTION_CLICK))
    }
}

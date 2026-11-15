package dev.yab.browser

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserSettings
import dev.yab.browser.model.BrowserSnapshot
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserSurface
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.WebsiteProfile
import dev.yab.browser.engine.GeckoEngine
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView

/** Exact shipped page.js in a real Gecko DOM. Only its fixture-local native port is stubbed.
 * The existing BrowserInstrumentedTest Reader case separately exercises the production port. */
@RunWith(AndroidJUnit4::class)
class ReaderDocumentTest {
    @Test(timeout = 240_000)
    fun safeStructureDocumentBindingBudgetsAndExactOriginalRestoration(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        OwnedLoopbackSiteSettings.reset()
        val source = instrumentation.targetContext.assets.open("web_extensions/yab/page.js").use { it.readBytes() }
        val fixture = instrumentation.context.assets.open("reader/structure.html").bufferedReader().use { it.readText() }
            .replace("__SOURCE_BASE64__", Base64.encodeToString(source, Base64.NO_WRAP))
        ReaderFixture(fixture).use { page ->
            val observation = ReaderObservation()
            BrowserInstrumentedTest().withBrowser(viewBound = observation::viewBound) { controller, engine ->
                observation.controller = controller; observation.engine = engine
                var primary: Throwable? = null
                try {
                val loadingDeadline = android.os.SystemClock.elapsedRealtime() + 30_000
                while (controller.state.value.loading) {
                    check(android.os.SystemClock.elapsedRealtime() < loadingDeadline) { "Original Controller did not load" }
                    delay(40)
                }
                observation.nativeStage = "OPENING"
                withContext(Dispatchers.Main) {
                    val space = BrowserSpace(BrowserController.PERSONAL_SPACE, "Reader DOM fixture")
                    controller.applySyncedSnapshot(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id,
                        settings = BrowserSettings(welcomed = true)))
                    controller.openUrl(page.url)
                    observation.captureSource()
                }
                observation.nativeStage = "AWAITING_TERMINAL"
                val deadline = android.os.SystemClock.elapsedRealtime() + 60_000
                while (true) {
                    val state = controller.state.value
                    observation.observeTitle(state.page.title, state.page.loading)
                    if (!state.page.loading && state.page.title in setOf("Reader source DOM passed", "Reader source DOM failed")) break
                    check(android.os.SystemClock.elapsedRealtime() < deadline) { "Reader DOM fixture did not finish" }
                    delay(40)
                }
                observation.nativeStage = "READING_RESULT"
                val tab = checkNotNull(controller.state.value.tab)
                val result = withContext(Dispatchers.Main) { engine.readText(tab) }
                observation.observeResult(result.text)
                observation.nativeStage = "ASSERTING_RESULT"
                assertEquals(page.url, tab.url)
                assertEquals("Reader source DOM passed", controller.state.value.page.title)
                assertTrue("The exact-resource DOM assertions must all complete", result.text.contains("READER_DOM_PASS checks="))
                assertTrue("Failure markers cannot be accepted", !result.text.contains("READER_DOM_FAIL"))
                observation.nativeStage = "COMPLETE"; observation.completed = true
                } catch (error: Throwable) { primary = error; throw error }
                finally {
                    try {
                        withContext(NonCancellable + Dispatchers.Main) {
                            val folder = File(checkNotNull(instrumentation.targetContext.getExternalFilesDir(null)), "instrumentation")
                            check(folder.isDirectory || folder.mkdirs())
                            File(folder, "reader-document.json").writeText(observation.json().put("http", page.diagnostics()).toString(2))
                        }
                    } catch (error: Throwable) { if (primary != null) primary!!.addSuppressed(error) else throw error }
                }
            }
        }
    }

    /** RAM-only original source/view observations. None authorizes or changes a test action. */
    private class ReaderObservation {
        lateinit var controller: BrowserController
        lateinit var engine: GeckoEngine
        var nativeStage = "LOADING"
        var completed = false
        private var fixtureStage = "UNKNOWN"
        private var failure = "NONE"
        private var assertion = "NONE"
        private var checks = 0
        private var loading = true
        private var titleKind = "UNKNOWN"
        private var originalTab: BrowserTab? = null
        private var originalProfile: WebsiteProfile? = null
        private var originalEpoch: Long? = null
        private var originalView: GeckoView? = null
        private var originalSession: GeckoSession? = null
        private var originalNative: GeckoEngine.ExternalActivityOwner? = null
        fun captureSource() {
            val state = controller.state.value
            originalTab = state.tab; originalProfile = state.space?.websiteProfile; originalEpoch = state.surfaceEpoch
        }
        fun viewBound(view: GeckoView) {
            if (!this::controller.isInitialized || !this::engine.isInitialized) return
            val tab = originalTab ?: return
            val profile = originalProfile ?: return
            val state = controller.state.value
            if (state.surface != BrowserSurface.PAGE || state.privateContentBlocked || state.tab?.id != tab.id ||
                state.tab?.url != tab.url || state.page.url != tab.url || state.space?.websiteProfile != profile ||
                state.surfaceEpoch != originalEpoch || view.tag != tab.id) return
            if (originalView == null) {
                val session = view.session ?: return
                originalView = view; originalSession = session
            }
            if (view !== originalView || view.session !== originalSession || originalNative != null || state.page.loading) return
            val native = engine.captureExternalActivityOwner() ?: return
            if (native.tab == tab.id && native.session === originalSession) originalNative = native
        }
        fun observeTitle(title: String?, isLoading: Boolean) {
            loading = isLoading
            val stage = title?.removePrefix("Reader DOM stage ") ?: "UNKNOWN"
            titleKind = when {
                title == "Reader DOM loading" -> "LOADING"
                title == "Reader source DOM passed" -> "PASSED"
                title == "Reader source DOM failed" -> "FAILED"
                title?.startsWith("Reader DOM stage ") == true && stage in stages -> { fixtureStage = stage; "STAGE" }
                else -> "UNKNOWN"
            }
        }
        fun observeResult(text: String) {
            val start = text.indexOf("READER_DOM_STATE ")
            if (start < 0) return
            val tail = text.substring(start + "READER_DOM_STATE ".length)
            val end = tail.indexOf(" END_READER_DOM_STATE")
            if (end !in 1..1024) return
            val state = runCatching { JSONObject(tail.substring(0, end)) }.getOrNull() ?: return
            fixtureStage = state.optString("stage").takeIf { it in stages } ?: "UNKNOWN"
            failure = state.optString("failure").takeIf { it in failures } ?: "UNKNOWN"
            assertion = state.optString("assertion").takeIf { it in assertions } ?: "UNKNOWN"
            checks = state.optInt("checks", -1).takeIf { it in 0..256 } ?: -1
        }
        fun json(): JSONObject {
            val state = controller.state.value
            val view = originalView
            val original = originalTab
            return JSONObject().put("schema", 1).put("completed", completed).put("nativeStage", nativeStage)
                .put("fixtureStage", fixtureStage).put("failureCategory", failure).put("assertionCode", assertion)
                .put("checks", checks).put("latestLoading", loading).put("titleKind", titleKind)
                .put("pageUrlMatchesOriginal", original != null && state.page.url == original.url)
                .put("pageHasTitle", !state.page.title.isNullOrEmpty()).put("pageHasError", state.page.error != null)
                .put("pageProgressPercent", (state.page.progress * 100).toInt().coerceIn(0, 100))
                .put("originalSourceCurrent", original != null && state.surface == BrowserSurface.PAGE &&
                    state.tab?.id == original.id && state.tab?.url == original.url && state.surfaceEpoch == originalEpoch &&
                    state.space?.websiteProfile == originalProfile && !state.privateContentBlocked)
                .put("originalNativeCaptured", originalNative != null)
                .put("originalNativeCurrent", originalNative?.let(engine::ownsExternalActivity) == true)
                .put("viewCaptured", view != null).put("viewAttached", view?.isAttachedToWindow == true)
                .put("viewShown", view?.isShown == true).put("viewWindowFocus", view?.hasWindowFocus() == true)
                .put("viewHasSize", view != null && view.width > 0 && view.height > 0)
                .put("sameViewSession", view != null && view.session === originalSession)
        }
        companion object {
            private val stages = setOf("SCRIPT_START", "SETUP", "NATIVE_PAGE_STYLE", "SOURCE_EXECUTE", "SOURCE_READY", "PORT_READY", "STALE_COMMANDS",
                "WAIT_FRAME_ONE", "WAIT_FRAME_TWO", "SCROLL_READY", "STRUCTURE", "STYLE_ROUNDTRIP", "STYLE_EDITS", "STYLE_NULL",
                "BUDGET_CHAR", "BUDGET_NODES", "BUDGET_TITLE", "BODY_REPLACEMENT", "COMPLETE")
            private val failures = setOf("NONE", "ASSERTION", "SYNTAX", "REFERENCE", "TYPE", "RANGE", "SECURITY", "OTHER")
            private val assertions = setOf("NONE", "NATIVE_ZOOM_READY", "ORIGINAL_LOCAL_PORT", "STALE_DOCUMENT_ENTER", "STALE_URL_ENTER", "BOOLEAN_ONLY",
                "REAL_SCROLL_BEFORE_READER", "ONE_READING_SURFACE", "ONE_TITLE", "HEADING_STRUCTURE", "LIST_STRUCTURE", "TABLE_STRUCTURE",
                "PROSE_STRUCTURE", "EMPHASIS_STRUCTURE", "PHONE_EXCLUDES_ALL_LINK_SUBTREES", "LINK_WORDS_EXCLUDED_WITH_SUBTREE",
                "NO_COPIED_ATTRIBUTES", "NO_ACTIVE_RESOURCE_NODES", "EXCLUDED_HIDDEN_ATTRIBUTE", "EXCLUDED_HIDDEN_ARIA",
                "EXCLUDED_HIDDEN_DISPLAY", "EXCLUDED_HIDDEN_VISIBILITY", "EXCLUDED_HIDDEN_OPACITY", "EXCLUDED_AROUND_ASIDE",
                "EXCLUDED_AROUND_RELATED", "EXCLUDED_ACTIVE_FORM", "EXCLUDED_ACTIVE_BUTTON", "EXCLUDED_TEMPLATE_WORDS",
                "NO_COPIED_HANDLER", "HIDDEN_ORIGINAL_BODY", "OWNED_ROOT_OVERFLOW", "REPEATED_ENTER_NO_REPLACEMENT",
                "STALE_DOCUMENT_EXIT", "STALE_URL_EXIT", "ORIGINAL_EXIT", "EXACT_STYLE_PRIORITY_ROUNDTRIP", "ORIGINAL_SCROLL_RESTORED",
                "LATER_ZOOM_AND_SITE_EDITS_PRESERVED", "ONLY_OWN_PROPERTIES_RESTORED", "NEW_OWNER_PROPERTIES_NOT_OVERWRITTEN",
                "ABSENT_STYLE_ATTRIBUTES_ROUNDTRIP", "CHARACTER_BUDGET_REFUSES_WHOLE_COPY", "NODE_BUDGET_REFUSES_WHOLE_COPY",
                "TITLE_CANNOT_BYPASS_CHARACTER_BUDGET", "FRESH_VALID_STRUCTURE_AFTER_REFUSAL", "REPORT_REMOVES_ORIGINAL_STALE_COVER",
                "REPLACEMENT_STYLES_UNTOUCHED", "NO_SCROLL_RESTORE_ON_REPLACEMENT", "STALE_READER_NOT_REPORTED_ENABLED",
                "OBSERVED_BODY_ABA_CANNOT_REACQUIRE_READER",
                "READABLE_STRUCTURE", "CHARACTER_BUDGET_READABLE", "NODE_BUDGET_READABLE", "TITLE_BUDGET_READABLE", "RESTORED_STRUCTURE_READABLE")
        }
    }

    private class ReaderFixture(private val html: String) : Closeable {
        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val live = AtomicBoolean(true)
        private val executor = Executors.newSingleThreadExecutor()
        private val accepted = AtomicInteger()
        private val requests = AtomicInteger()
        private val headers = AtomicInteger()
        private val responses = AtomicInteger()
        private val ioFailures = AtomicInteger()
        private val worker: Future<*>
        val url = "http://127.0.0.1:${server.localPort}/reader"
        init {
            worker = executor.submit {
                while (live.get()) {
                    val socket = try { server.accept() } catch (_: SocketException) { break }
                    accepted.incrementAndGet()
                    try {
                        socket.use { client ->
                            client.soTimeout = 5000
                            val input = client.getInputStream().bufferedReader()
                            input.readLine() ?: return@use
                            requests.incrementAndGet()
                            while (!input.readLine().isNullOrEmpty()) { /* Drain this owned fixture request. */ }
                            headers.incrementAndGet()
                            val body = html.toByteArray(Charsets.UTF_8)
                            client.getOutputStream().apply {
                                write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray())
                                write(body); flush()
                            }
                            responses.incrementAndGet()
                        }
                    } catch (_: IOException) {
                        // A cancelled speculative connection must not end this
                        // fixture's only accept loop before the document request.
                        ioFailures.incrementAndGet()
                    }
                }
            }
        }
        fun diagnostics(): JSONObject = JSONObject()
            .put("accepted", accepted.get()).put("requests", requests.get()).put("headers", headers.get())
            .put("responses", responses.get()).put("ioFailures", ioFailures.get())
            .put("workerDoneBeforeClose", worker.isDone).put("liveBeforeClose", live.get())
        override fun close() { live.set(false); server.close(); executor.shutdownNow() }
    }
}

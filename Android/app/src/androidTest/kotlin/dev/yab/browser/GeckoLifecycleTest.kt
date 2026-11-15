package dev.yab.browser

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Rect
import android.os.Process
import android.os.SystemClock
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.BrowserController
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONArray
import org.json.JSONObject

/** Native content processes and session state are exercised, never replaced with an engine fake. */
@RunWith(AndroidJUnit4::class)
class GeckoLifecycleTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val fixture = BrowserInstrumentedTest()

    @Test(timeout = 300_000)
    fun safeSessionBudgetRestoresRealBackAndScrollAfterEviction(): Unit = runBlocking {
        BrowserInstrumentedTest.FixtureServer().use { server ->
            fixture.withBrowser { browser, engine ->
              functional("eviction", browser, engine) { trace ->
                main { fixture.ownSpace(browser, "Eviction fixture"); browser.openUrl(server.url("/safe/original")) }
                ready(browser, "original")
                val originalId = browser.state.value.tab!!.id
                swipeUp()
                await("native scroll observation") { browser.state.value.page.scrollY > 200 }
                val originalScroll = navigateFromSteadyScroll(browser, engine, originalId,
                    server.url("/safe/original"), server.url("/safe/second"), trace)
                ready(browser, "second")
                trace.capture(FunctionalPhase.SECOND_READY)
                assertTrue(browser.state.value.page.canGoBack)
                loadPressure(browser, server)
                await("safe native session budget", 60_000) { engine.liveSessionCount <= 6 && !engine.hasLiveSession(originalId) }
                trace.capture(FunctionalPhase.ORIGINAL_EVICTED)
                main { browser.selectTab(originalId) }
                ready(browser, "second")
                trace.capture(FunctionalPhase.RESTORED_SECOND)
                assertTrue("Eviction lost native Back", browser.state.value.page.canGoBack)
                main { assertTrue(browser.back()) }
                ready(browser, "original")
                trace.capture(FunctionalPhase.BACK_ORIGINAL_READY)
                val scrollDeadline = SystemClock.elapsedRealtime() + 30_000
                while (true) {
                    trace.capture(FunctionalPhase.RESTORING_SCROLL, timedScroll = true)
                    if (abs(browser.state.value.page.scrollY - originalScroll) < 180) break
                    check(SystemClock.elapsedRealtime() < scrollDeadline) { "Timed out waiting for original scroll restored" }
                    delay(50)
                }
                fixture.shot("browser-evicted-native-back-scroll.png")
              }
            }
        }
    }

    @Test(timeout = 300_000)
    fun unsentFormAndUnknownFrameAreKeptWhileSafePagesCanEvict(): Unit = runBlocking {
        BrowserInstrumentedTest.FixtureServer().use { server ->
            fixture.withBrowser { browser, engine ->
              functional("form", browser, engine) { trace ->
                main { fixture.ownSpace(browser, "Protected content"); browser.openUrl(server.url("/dirty")) }
                await("form load") { browser.state.value.page.title == "Unsent form" && !browser.state.value.page.loading }
                val dirty = browser.state.value.tab!!.id
                trace.capture(FunctionalPhase.FORM_READY)
                clickFunctional("Edit form", browser, trace, FunctionalPhase.EDIT_CONTROL)
                await("real input edit observation") { browser.state.value.page.hasFormEdits }
                trace.capture(FunctionalPhase.FORM_EDITED)
                main { browser.openUrl(server.url("/uncertain")) }
                await("embedded-frame observation") { browser.state.value.page.title == "Embedded frame" && browser.state.value.page.frameUncertain && !browser.state.value.page.loading }
                val framed = browser.state.value.tab!!.id
                trace.capture(FunctionalPhase.FRAME_READY)
                loadPressure(browser, server)
                await("protected pages within budget", 60_000) { engine.liveSessionCount <= 6 }
                trace.capture(FunctionalPhase.PRESSURE_FINISHED)
                assertTrue("An unsent form was evicted", engine.hasLiveSession(dirty))
                assertTrue("A page with unknown frame state was evicted", engine.hasLiveSession(framed))
                main { browser.selectTab(dirty) }
                clickFunctional("Read form", browser, trace, FunctionalPhase.READ_CONTROL)
                awaitFunctionalText(browser, engine, "Draft=unsent notes", trace, FunctionalPhase.FORM_TEXT)
                fixture.shot("browser-protected-unsent-form.png")
              }
            }
        }
    }

    @Test(timeout = 300_000)
    fun privateCookiesRemainInRamUnderPressureWithoutStateOrThumbnails(): Unit = runBlocking {
        BrowserInstrumentedTest.FixtureServer().use { server ->
            fixture.withBrowser { browser, engine ->
              functional("cookie", browser, engine) { trace ->
                main {
                    fixture.ownSpace(browser, "Public pressure")
                    browser.updateSettings(browser.state.value.settings.copy(lockPrivate = false))
                    browser.openUrl(server.url("/safe/thumbnail"))
                }
                ready(browser, "thumbnail")
                val publicId = browser.state.value.tab!!.id
                await("positive public compositor thumbnail", 20_000) { engine.thumbnails.value[publicId] != null }
                assertTrue(engine.thumbnails.value[publicId]!!.bitmap.width > 0)
                main {
                    browser.openUrl(server.url("/cookie/write?value=private-ram"), privately = true)
                }
                val privateId = browser.state.value.tab!!.id
                awaitFunctionalText(browser, engine, "Cookie=private-ram Storage=private-ram", trace, FunctionalPhase.COOKIE_WRITE_BEFORE_PRESSURE)
                val publicSpace = browser.state.value.spaces.first { !it.isPrivate && it.name == "Public pressure" }.id
                main { browser.selectSpace(publicSpace) }
                loadPressure(browser, server)
                await("public sessions settle with the original Private session evicted", 60_000) {
                    engine.liveSessionCount <= 6 && !engine.hasLiveSession(privateId)
                }
                trace.capture(FunctionalPhase.PRESSURE_FINISHED)
                assertNull("Private pixels entered the thumbnail store", engine.thumbnails.value[privateId])
                val file = File(instrumentation.targetContext.filesDir, "navigation/${UUID.nameUUIDFromBytes(privateId.toByteArray())}.json")
                assertFalse("Private navigation entered persistence", file.exists())
                assertFalse(browser.publicSnapshot().toString().contains("private-ram"))
                main { browser.selectTab(privateId); browser.openUrl(server.url("/cookie/read"), newTab = false) }
                awaitFunctionalText(browser, engine, "Cookie=private-ram Storage=private-ram", trace, FunctionalPhase.COOKIE_READ_AFTER_PRESSURE)
                assertNull(engine.thumbnails.value[privateId])
                assertFalse(file.exists())
              }
            }
        }
    }

    @Test(timeout = 300_000)
    fun killedOwnedContentProcessRecreatesItsSessionAndNativeBack(): Unit = runBlocking {
        assumeTrue("Process fault injection requires the disposable runner device", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val paints = RecoveryPaintObservation()
        val viewport = RecoveryViewportProof(paints)
        BrowserInstrumentedTest.FixtureServer().use { server ->
            fixture.withBrowser(viewBound = paints::watchBound) { browser, engine ->
                main { fixture.ownSpace(browser, "Crash fixture"); browser.openUrl(server.url("/safe/before-crash")) }
                ready(browser, "before-crash")
                main { browser.openUrl(server.url("/safe/after-crash"), newTab = false); engine.saveSessions() }
                ready(browser, "after-crash")
                val tab = browser.state.value.tab!!
                val profile = browser.state.value.space!!.websiteProfile
                val original = main { engine.session(tab, profile) }
                val file = File(instrumentation.targetContext.filesDir, "navigation/${UUID.nameUUIDFromBytes(tab.id.toByteArray())}.json")
                main { engine.saveSessions() }
                await("fresh native checkpoint", 20_000) { file.isFile && file.readText().contains("after-crash") }
                val controlInk = viewport.requireVisible("foreground-before", browser, engine)
                val faultBoundary = System.nanoTime()
                crashOwnedContentProcesses()
                awaitMain("automatic replacement of the crashed native session", 30_000) {
                    engine.hasLiveSession(tab.id) && engine.session(tab, profile) !== original
                }
                ready(browser, "after-crash")
                assertNull(browser.state.value.page.error)
                assertEquals("IDLE", main { engine.recoveryStatus(tab.id) })
                assertTrue(browser.state.value.page.canGoBack)
                main { assertTrue(browser.back()) }
                ready(browser, "before-crash")
                awaitPageText(browser, engine, "delivery city is Oslo")
                viewport.requireVisible("foreground-recovered", browser, engine, faultBoundary, controlInk)
                fixture.shot("browser-native-process-recovered.png")
            }
        }
    }

    /** This drives the engine background/foreground API, not Android Activity lifecycle delivery. */
    @Test(timeout = 300_000)
    fun engineBackgroundDefersOwnedProcessRecoveryUntilEngineForeground(): Unit = runBlocking {
        assumeTrue("Process fault injection requires the disposable runner device", InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val paints = RecoveryPaintObservation()
        val viewport = RecoveryViewportProof(paints)
        BrowserInstrumentedTest.FixtureServer().use { server ->
            fixture.withBrowser(viewBound = paints::watchBound) { browser, engine ->
                main { fixture.ownSpace(browser, "Deferred crash fixture"); browser.openUrl(server.url("/safe/background-before")) }
                ready(browser, "background-before")
                main { browser.openUrl(server.url("/safe/background-after"), newTab = false) }
                ready(browser, "background-after")
                val tab = browser.state.value.tab!!
                val profile = browser.state.value.space!!.websiteProfile
                val original = main { engine.session(tab, profile).also { engine.saveSessions() } }
                val file = File(instrumentation.targetContext.filesDir, "navigation/${UUID.nameUUIDFromBytes(tab.id.toByteArray())}.json")
                await("background native checkpoint", 20_000) { file.isFile && file.readText().contains("background-after") }
                val controlInk = viewport.requireVisible("deferred-before", browser, engine)
                val faultBoundary = System.nanoTime()
                try {
                    main { engine.background() }
                    crashOwnedContentProcesses()
                    awaitMain("real crash held as deferred while the engine is away", 30_000) {
                        !engine.hasLiveSession(tab.id) && engine.recoveryStatus(tab.id) == "DEFERRED"
                    }
                    assertSame(original, main { engine.session(tab, profile) })
                    assertNull(browser.state.value.page.error)
                    main { engine.foreground() }
                    awaitMain("foreground starts a new native session", 30_000) {
                        engine.hasLiveSession(tab.id) && engine.session(tab, profile) !== original
                    }
                    ready(browser, "background-after")
                    assertNull(browser.state.value.page.error)
                    assertTrue(browser.state.value.page.canGoBack)
                    main { assertTrue(browser.back()) }
                    ready(browser, "background-before")
                    awaitPageText(browser, engine, "delivery city is Oslo")
                    viewport.requireVisible("deferred-recovered", browser, engine, faultBoundary, controlInk)
                    fixture.shot("browser-native-deferred-process-recovered.png")
                } finally { main { engine.foreground() } }
            }
        }
    }

    private fun crashOwnedContentProcesses() {
        val context = instrumentation.targetContext
        val packageName = context.packageName
        val appUid = context.applicationInfo.uid
        assertEquals("Fault fixture must execute under the target application's UID", appUid, Process.myUid())
        // Read this compiled APK's actual process names. Gecko's service class and Android
        // process suffix are different (the pinned AAR uses :tab_disable_art_image_N).
        // Isolated/zygote services are deliberately outside this normal-UID fault fixture.
        val contentClass = Regex("^org\\.mozilla\\.gecko\\.process\\.GeckoChildProcessServices\\\$tab(?:[0-9]|[1-3][0-9])$")
        val processNames = context.packageManager.getPackageInfo(packageName, PackageManager.GET_SERVICES).services.orEmpty()
            .filter { service -> service.packageName == packageName && service.applicationInfo?.packageName == packageName &&
                service.applicationInfo?.uid == appUid && !service.exported &&
                (service.flags and ServiceInfo.FLAG_ISOLATED_PROCESS) == 0 && contentClass.matches(service.name) }
            .mapNotNull { it.processName?.takeIf { process -> process.startsWith("$packageName:") } }.toSet()
        assertTrue("No compiled normal-UID Gecko content service; isolated fault injection is unsupported", processNames.isNotEmpty())
        fun owned(process: ActivityManager.RunningAppProcessInfo): Boolean = process.pid > 0 && process.pid != Process.myPid() &&
            process.uid == appUid && process.processName in processNames && process.pkgList?.toSet() == setOf(packageName)
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val processes = manager.runningAppProcesses.orEmpty().filter(::owned)
        assertTrue("No running normal-UID Gecko content process; no isolated-process fault was attempted", processes.isNotEmpty())
        var injected = 0
        for (process in processes) {
            val current = manager.runningAppProcesses.orEmpty().firstOrNull { it.pid == process.pid } ?: continue
            assertTrue("Owned content process identity changed before fault injection",
                owned(current) && current.processName == process.processName && current.uid == process.uid &&
                    current.pkgList?.toSet() == process.pkgList?.toSet())
            // An unannounced death of this already rechecked same-UID child,
            // rather than am crash's deliberate Java app-crash dialog.
            Process.killProcess(process.pid)
            injected++
        }
        assertTrue("No owned Gecko content process remained for the actual fault", injected > 0)
    }

    private suspend fun awaitMain(name: String, timeout: Long, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (!main(predicate)) { check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $name" }; delay(50) }
    }

    private suspend fun loadPressure(browser: BrowserController, server: BrowserInstrumentedTest.FixtureServer) {
        repeat(9) { index ->
            main { browser.openUrl(server.url("/safe/pressure-$index")) }
            ready(browser, "pressure-$index")
        }
    }

    private suspend fun ready(browser: BrowserController, name: String) = await("$name safe native document", 60_000) {
        browser.state.value.page.let { it.title == "Safe page $name" && !it.loading && it.progress >= 1f && it.safeToClear && !it.frameUncertain }
    }

    private suspend fun awaitPageText(browser: BrowserController, engine: GeckoEngine, text: String) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (SystemClock.elapsedRealtime() < deadline) {
            val result = runCatching { mainSuspend { engine.readText(browser.state.value.tab!!).text } }.getOrNull()
            if (result?.contains(text) == true) return
            delay(100)
        }
        error("Native document did not contain $text")
    }

    private enum class FunctionalPhase {
        START, FORM_READY, EDIT_CONTROL, FORM_EDITED, FRAME_READY, PRESSURE_FINISHED, READ_CONTROL, FORM_TEXT,
        COOKIE_WRITE_BEFORE_PRESSURE, COOKIE_READ_AFTER_PRESSURE, ORIGINAL_SCROLL, SECOND_READY,
        ORIGINAL_EVICTED, RESTORED_SECOND, BACK_ORIGINAL_READY, RESTORING_SCROLL, ORIGINAL_SCROLL_SETTLING
    }

    /** This test fixture never exports a page title, URL, profile/tab ID, cookie or exception text. */
    private inner class FunctionalDiagnostics(val kind: String, val browser: BrowserController, val engine: GeckoEngine) {
        private val samples = JSONArray()
        private val checkpoints = JSONArray()
        private val started = SystemClock.elapsedRealtime()
        private var sampledAt = Long.MIN_VALUE
        private var phase = FunctionalPhase.START
        var expectedScroll: Float? = null
        var readOutcome = "NOT_REQUESTED"
        var readAttempts = 0
        var textLength = 0
        var expectedTextFound = false
        var control = JSONObject()

        private fun number(value: Float): Any = if (value.isFinite()) value.coerceIn(0f, 1_000_000f).toDouble() else JSONObject.NULL

        private fun state(): JSONObject {
            val current = browser.state.value
            val tab = current.tab
            val page = current.page
            val read = engine.textReadDiagnostics(tab?.id)
            val bridge = JSONObject().put("stage", read.optString("stage").takeIf {
                it in setOf("NO_SESSION", "IDLE", "WAITING_BRIDGE", "REQUEST_SENT", "RECEIVED", "OWNER_REVOKED", "TIMED_OUT", "CANCELLED", "FAILED")
            } ?: "UNKNOWN")
            for (key in listOf("installed", "connected", "contentDocumentKnown", "owned", "loading", "viewBound", "viewAttached", "viewSessionCurrent", "visible")) {
                bridge.put(key, (read.opt(key) as? Boolean) ?: JSONObject.NULL)
            }
            for (key in listOf("connections", "messages")) bridge.put(key, (read.opt(key) as? Number)?.toLong()?.coerceIn(0, 1_000_000) ?: JSONObject.NULL)
            return JSONObject().put("tabPresent", tab != null).put("pageSurface", current.surface == dev.yab.browser.model.BrowserSurface.PAGE)
                .put("private", current.space?.isPrivate == true).put("privateBlocked", current.privateContentBlocked)
                .put("tabPrivacyMatchesSpace", tab != null && tab.isPrivate == current.space?.isPrivate)
                .put("loading", page.loading).put("progress", number(page.progress)).put("pageError", page.error != null)
                .put("safeToClear", page.safeToClear).put("frameUncertain", page.frameUncertain).put("hasFormEdits", page.hasFormEdits)
                .put("canGoBack", page.canGoBack).put("scrollY", number(page.scrollY))
                .put("expectedScroll", expectedScroll?.let(::number) ?: JSONObject.NULL)
                .put("liveSession", tab != null && engine.hasLiveSession(tab.id)).put("liveCount", engine.liveSessionCount.coerceIn(0, 1_000))
                .put("fixtureTitle", when (page.title) { "Unsent form" -> "FORM"; "Embedded frame" -> "FRAME"; "Cookie write" -> "COOKIE_WRITE"; "Cookie read" -> "COOKIE_READ"; "Safe page original" -> "ORIGINAL"; "Safe page second" -> "SECOND"; else -> "OTHER" })
                .put("readOutcome", readOutcome).put("readAttempts", readAttempts.coerceIn(0, 1_000_000))
                .put("textLength", textLength.coerceIn(0, 12_000)).put("expectedTextFound", expectedTextFound)
                .put("bridge", bridge).put("control", control).put("privateKeeper", engine.privateKeeperDiagnostics())
        }

        private fun record(next: FunctionalPhase, now: Long, timedScroll: Boolean) {
            val changed = next != phase
            phase = next
            if (!changed && sampledAt != Long.MIN_VALUE && now - sampledAt < if (timedScroll) 500 else 1000) return
            sampledAt = now
            val sample = state().put("phase", phase.name).put("elapsedMs", (now - started).coerceIn(0, 300_000))
            if (changed && checkpoints.length() < 16) checkpoints.put(sample)
            if (samples.length() >= 32) samples.remove(0)
            samples.put(sample)
        }

        suspend fun capture(next: FunctionalPhase, timedScroll: Boolean = false) = main {
            record(next, SystemClock.elapsedRealtime(), timedScroll)
        }

        /** Called on Main in the same non-suspending block as the real navigation. */
        fun captureAtNavigation(scroll: Float) {
            expectedScroll = scroll
            record(FunctionalPhase.ORIGINAL_SCROLL, SystemClock.elapsedRealtime(), false)
        }

        suspend fun finish(completed: Boolean): Boolean = withContext(NonCancellable) {
            // Artifact failure must not replace the original scenario assertion.
            try {
                val final = main { state() }
                val value = JSONObject().put("schema", 1).put("case", kind).put("completed", completed)
                    .put("phase", phase.name).put("phaseCheckpoints", checkpoints).put("samples", samples).put("final", final)
                withContext(Dispatchers.IO) {
                    val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation").apply { check(isDirectory || mkdirs()) }
                    File(folder, "lifecycle-functional-$kind.json").writeText(value.toString(2))
                }
                true
            } catch (_: Exception) { false }
        }
    }

    private suspend fun navigateFromSteadyScroll(browser: BrowserController, engine: GeckoEngine, tabId: String,
        originalUrl: String, destination: String, trace: FunctionalDiagnostics): Float {
        val profile = main { checkNotNull(browser.state.value.space).websiteProfile }
        val deadline = SystemClock.elapsedRealtime() + 10_000
        var previous = Float.NaN
        var stableSince = 0L
        while (true) {
            val baseline = main {
                val current = browser.state.value
                val page = current.page
                val bridge = engine.textReadDiagnostics(tabId)
                check(current.tab?.id == tabId && current.space?.websiteProfile == profile &&
                    current.tab?.url == originalUrl && page.url == originalUrl &&
                    current.surface == dev.yab.browser.model.BrowserSurface.PAGE && !current.privateContentBlocked &&
                    !page.loading && page.progress >= 1f && page.safeToClear && !page.frameUncertain && page.error == null &&
                    engine.hasLiveSession(tabId) && bridge.optBoolean("owned") && bridge.optBoolean("viewSessionCurrent")) {
                    "The original native scroll owner changed before navigation"
                }
                val scroll = page.scrollY
                check(scroll.isFinite() && scroll >= 0f) { "Invalid owned native scroll position" }
                val now = SystemClock.elapsedRealtime()
                if (scroll != previous) { previous = scroll; stableSince = now }
                // page.js debounces DOM scroll observations by120ms. Observe an
                // unchanged native/DOM projection across several such periods;
                // the original >200 prerequisite and <180 restore tolerance stay.
                if (scroll > 200 && now - stableSince >= 600) {
                    trace.captureAtNavigation(scroll)
                    browser.openUrl(destination, newTab = false)
                    scroll
                } else null
            }
            if (baseline != null) return baseline
            trace.capture(FunctionalPhase.ORIGINAL_SCROLL_SETTLING, timedScroll = true)
            check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for steady original scroll before navigation" }
            delay(50)
        }
    }

    private suspend fun functional(kind: String, browser: BrowserController, engine: GeckoEngine, block: suspend (FunctionalDiagnostics) -> Unit) {
        require(kind in setOf("form", "cookie", "eviction"))
        val trace = FunctionalDiagnostics(kind, browser, engine)
        var completed = false
        try { block(trace); completed = true }
        finally {
            val saved = trace.finish(completed)
            if (completed) assertTrue("Owned functional diagnostics were not saved", saved)
        }
    }

    private suspend fun awaitFunctionalText(browser: BrowserController, engine: GeckoEngine, expected: String,
        trace: FunctionalDiagnostics, phase: FunctionalPhase) {
        trace.expectedTextFound = false
        trace.textLength = 0
        trace.readOutcome = "NOT_REQUESTED"
        trace.capture(phase)
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (SystemClock.elapsedRealtime() < deadline) {
            trace.readAttempts++
            try {
                val result = mainSuspend { engine.readText(browser.state.value.tab!!, diagnostics = true).text }
                trace.textLength = result.length
                trace.expectedTextFound = result.contains(expected)
                trace.readOutcome = if (trace.expectedTextFound) "RECEIVED_MATCH" else "RECEIVED_OTHER"
            } catch (error: CancellationException) { throw error }
            catch (_: IllegalStateException) { trace.expectedTextFound = false; trace.textLength = 0; trace.readOutcome = "READ_REFUSED" }
            catch (_: Exception) { trace.expectedTextFound = false; trace.textLength = 0; trace.readOutcome = "READ_FAILED" }
            trace.capture(phase)
            if (trace.expectedTextFound) return
            delay(100)
        }
        error("Native document did not contain $expected")
    }

    private suspend fun clickFunctional(text: String, browser: BrowserController, trace: FunctionalDiagnostics, phase: FunctionalPhase) {
        require(text == "Edit form" || text == "Read form")
        val expectedPackage = instrumentation.targetContext.packageName
        val tab = browser.state.value.tab?.id
        trace.capture(phase)
        var actionSucceeded = false
        await("$text control") {
            val root = instrumentation.uiAutomation.rootInActiveWindow
            val owned = root?.packageName?.toString() == expectedPackage
            val queue = java.util.ArrayDeque<AccessibilityNodeInfo>()
            val candidates = mutableListOf<AccessibilityNodeInfo>()
            val states = JSONArray()
            var visited = 0; var textMatches = 0; var descriptionMatches = 0
            var capped = false
            val window = root?.windowId
            if (owned) queue.add(requireNotNull(root)) else root?.recycle()
            var clicked = false
            var attempted = false
            try {
                while (queue.isNotEmpty() && visited < 1_024) {
                    val node = queue.removeFirst(); visited++
                    try {
                        if (node.packageName?.toString() != expectedPackage) continue
                        val sameText = node.text?.toString() == text
                        val sameDescription = node.contentDescription?.toString() == text
                        if (sameText) textMatches++
                        if (sameDescription) descriptionMatches++
                        if ((sameText || sameDescription) && states.length() < 4) {
                            val bounds = Rect(); node.getBoundsInScreen(bounds)
                            states.put(JSONObject().put("visible", node.isVisibleToUser).put("enabled", node.isEnabled).put("clickable", node.isClickable)
                                .put("actionClick", node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK })
                                .put("bounds", JSONArray(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).map { it.coerceIn(-1_000_000, 1_000_000) })))
                        }
                        if ((sameText || sameDescription) && node.isVisibleToUser && node.isEnabled && node.isClickable) candidates.add(AccessibilityNodeInfo.obtain(node))
                        if (node.childCount > 128) capped = true
                        repeat(node.childCount.coerceAtMost(128)) {
                            if (visited + queue.size >= 1_024) capped = true else node.getChild(it)?.let(queue::add)
                        }
                    } finally { node.recycle() }
                }
                capped = capped || queue.isNotEmpty()
                if (!capped && candidates.size == 1 && browser.state.value.tab?.id == tab && !browser.state.value.privateContentBlocked) {
                    val fresh = instrumentation.uiAutomation.rootInActiveWindow
                    try {
                        if (fresh != null && fresh.packageName?.toString() == expectedPackage && fresh.windowId == window) {
                            attempted = true
                            clicked = candidates.single().performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        }
                    } finally { fresh?.recycle() }
                }
            } finally { candidates.forEach { it.recycle() }; queue.forEach { it.recycle() } }
            trace.control = JSONObject().put("rootPresent", root != null).put("rootOwned", owned).put("visited", visited).put("capped", capped)
                .put("textMatches", textMatches).put("descriptionMatches", descriptionMatches).put("actionable", candidates.size)
                .put("knownControl", if (text == "Edit form") "EDIT" else "READ").put("states", states).put("clicked", clicked)
            actionSucceeded = clicked
            attempted
        }
        assertTrue("Native $text control click failed", actionSucceeded)
        trace.capture(phase)
    }

    private fun swipeUp() {
        val metrics = instrumentation.targetContext.resources.displayMetrics
        val down = SystemClock.uptimeMillis()
        val x = metrics.widthPixels / 2f
        val start = metrics.heightPixels * .7f
        val end = metrics.heightPixels * .28f
        for (step in 0..10) {
            val action = when (step) { 0 -> MotionEvent.ACTION_DOWN; 10 -> MotionEvent.ACTION_UP; else -> MotionEvent.ACTION_MOVE }
            val event = MotionEvent.obtain(down, down + step * 25L, action, x, start + (end - start) * step / 10f, 0)
            event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
            assertTrue("Native touch injection failed", instrumentation.uiAutomation.injectInputEvent(event, true))
            event.recycle()
        }
    }

    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
    private suspend fun <T> mainSuspend(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }
    private suspend fun await(name: String, timeout: Long = 15_000, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (!predicate()) { check(SystemClock.elapsedRealtime() < deadline) { "Timed out waiting for $name" }; delay(50) }
    }
}

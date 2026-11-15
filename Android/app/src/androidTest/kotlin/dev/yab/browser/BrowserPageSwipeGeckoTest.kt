package dev.yab.browser

import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserChromeFrame
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.mozilla.geckoview.GeckoView

/** Real native sessions and finger input. Numerical/controlled motion tests are separate;
 * this proves live neighbor identity, never presented-frame or physical smoothness. */
class BrowserPageSwipeGeckoTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test(timeout = 180_000)
    fun actualHeldNativeNeighborReusesTheSameViewAndSessionWhenSelected(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val frames = AtomicReference<BrowserChromeFrame?>()
        val views = ConcurrentHashMap<String, GeckoView>()
        val receipt = JSONObject().put("passed", false).put("realGecko", true).put("realPointer", true)
            .put("presentedFrameParityVerified", false).put("physicalDeviceSmoothnessVerified", false)
        try {
            BrowserInstrumentedTest.FixtureServer().use { server ->
                BrowserInstrumentedTest().withBrowser(chromeFrames = frames::set, viewBound = { view ->
                    (view.tag as? String)?.let { views[it] = view }
                }, paging = true) { browser, engine ->
                    main { BrowserInstrumentedTest().ownSpace(browser, "Native paging"); browser.openUrl(server.url("/safe/paging-first")) }
                    ready(browser, "paging-first")
                    val after = checkNotNull(browser.state.value.tab)
                    main { browser.openUrl(server.url("/safe/paging-front")) }
                    ready(browser, "paging-front")
                    val front = checkNotNull(browser.state.value.tab)
                    await("the actual plate frame") { frames.get()?.boundsPx?.width?.let { it > 100 } == true }
                    val lease = main { checkNotNull(browser.capturePageSwipe()) }
                    assertEquals(after.id, lease.after?.id)
                    val sourceSession = main { engine.session(front, lease.profile) }
                    val plate = checkNotNull(frames.get())
                    val startX = plate.boundsPx.center.x
                    val y = plate.boundsPx.center.y
                    val targetX = startX - 180f * plate.density
                    val down = SystemClock.uptimeMillis()
                    var pressed = true
                    fun inject(action: Int, x: Float) {
                        val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0).apply {
                            source = InputDevice.SOURCE_TOUCHSCREEN
                        }
                        try { assertTrue("Native paging input was refused", instrumentation.uiAutomation.injectInputEvent(event, true)) }
                        finally { event.recycle() }
                    }
                    try {
                        inject(MotionEvent.ACTION_DOWN, startX)
                        for (step in 1..18) {
                            delay(16)
                            inject(MotionEvent.ACTION_MOVE, startX + (targetX - startX) * step / 18f)
                        }
                        await("both held native page views") { views[front.id]?.isAttachedToWindow == true && views[after.id]?.isAttachedToWindow == true }
                        assertEquals("A held finger changed selection", front.id, browser.state.value.tab?.id)
                        val incoming = checkNotNull(views[after.id])
                        val incomingSession = main { checkNotNull(incoming.session) }
                        assertNotSame(sourceSession, incomingSession)
                        val held = main {
                            val origin = IntArray(2).also(incoming::getLocationOnScreen)
                            JSONObject().put("frontRemainsSelected", engine.selected == front.id)
                                .put("frontViewAttached", views[front.id]?.isAttachedToWindow == true)
                                .put("neighborViewAttached", incoming.isAttachedToWindow)
                                .put("neighborSessionIsLive", engine.hasLiveSession(after.id))
                                .put("neighborLocationPx", org.json.JSONArray(listOf(origin[0], origin[1])))
                                .put("neighborSizePx", org.json.JSONArray(listOf(incoming.width, incoming.height)))
                        }
                        assertTrue(held.getBoolean("frontRemainsSelected"))
                        assertTrue(held.getBoolean("neighborSessionIsLive"))
                        receipt.put("held", held)
                        delay(200)
                        inject(MotionEvent.ACTION_UP, targetX); pressed = false
                        await("the captured neighbor actually selected") { browser.state.value.tab?.id == after.id && engine.selected == after.id }
                        ready(browser, "paging-first")
                        await("the original incoming view remains attached") { views[after.id]?.isAttachedToWindow == true }
                        main {
                            assertSame("Selection recreated the incoming native view", incoming, views[after.id])
                            assertSame("Selection recreated the incoming native session", incomingSession, incoming.session)
                            assertTrue(engine.ownsInteractive(incomingSession))
                        }
                        receipt.put("sameNativeViewAfterSelection", true).put("sameNativeSessionAfterSelection", true)
                            .put("capturedNeighborSelected", true).put("passed", true)
                    } finally { if (pressed) inject(MotionEvent.ACTION_CANCEL, targetX) }
                }
            }
        } finally {
            val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/native-paging").apply { check(isDirectory || mkdirs()) }
            File(folder, "held-native-neighbor.json").writeText(receipt.toString(2))
        }
    }

    private suspend fun ready(browser: BrowserController, name: String) = await("owned $name document") {
        browser.state.value.page.let { !it.loading && it.progress >= 1f && it.title == "Safe page $name" }
    }
    private suspend fun await(name: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 25_000
        while (!predicate()) { check(SystemClock.elapsedRealtime() < deadline) { "Timed out: $name" }; delay(40) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
}

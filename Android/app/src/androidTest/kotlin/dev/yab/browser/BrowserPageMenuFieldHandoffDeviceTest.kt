package dev.yab.browser

import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Shipped Screen/menu/Field with an actual Gecko owner, owned native input and explicit
 * component-animation override. This is consumer geometry, not presented pixels/cadence. */
class BrowserPageMenuFieldHandoffDeviceTest {
    private data class Draw(val frame: PageMenuFrame, val pose: BrowserPageMenuPose, val nanos: Long)
    private val fixture = BrowserInstrumentedTest()
    private val draws = CopyOnWriteArrayList<Draw>()
    @Volatile private var latest: Draw? = null
    private val milestones = JSONArray()

    @Test(timeout = 180_000)
    fun originalNativeMenuRowStartsTheAddressFieldImmediatelyAndBothLandOnItsMeasuredKeyboardTarget(): Unit = runBlocking {
        use("land") { browser, engine, ui ->
            val tab = browser.state.value.tab!!
            val profile = browser.state.value.space!!.websiteProfile
            val session = main { engine.session(tab, profile) }
            val oldEpoch = browser.state.value.surfaceEpoch
            open(ui)
            val row = latest!!.pose.row
            val before = draws.size
            mark("ADDRESS_CALL")
            ui.click("Edit address")
            mark("ADDRESS_UP_RETURNED")
            await("actual Field begins without the plate exit") { browser.state.value.surface == BrowserSurface.FIELD }
            main {
                val field = browser.state.value
                assertEquals(oldEpoch + 1, field.surfaceEpoch)
                assertFalse(field.fieldIsNewTab)
                val anchor = checkNotNull(field.fieldAnchor)
                assertEquals(row.width, anchor.width, .01); assertEquals(row.height, anchor.height, .01)
                assertEquals(tab.id, field.fieldOriginTab)
                assertEquals(tab.url, field.fieldText)
            }
            await("intermediate outgoing sheet uses a real measured Field") {
                draws.drop(before).any { it.frame.phase == PageMenuPhase.HANDING_OFF && it.frame.toField in .05.. .95 && it.pose.measuredField != null }
            }
            val flight = draws.drop(before).filter { it.frame.phase == PageMenuPhase.HANDING_OFF }
            assertTrue(flight.isNotEmpty())
            assertFalse(draws.drop(before).any { it.frame.phase == PageMenuPhase.CLOSING })
            assertTrue(flight.all { !it.frame.interactive && it.pose.measuredField != null })
            assertTrue(flight.any { it.pose.bodyOpacity < .1 && it.pose.rowOpacity > .5 })
            await("outgoing menu released only after its field flight") { latest?.frame?.toField?.let { it > .95 } == true }
            ui.menuAbsent(); ui.absent("Copy"); ui.absent("Find on Page")
            main {
                assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
                assertTrue(engine.session(tab, profile) === session)
            }
            mark("FIELD_REMAINS")
        }
    }

    @Test(timeout = 180_000)
    fun fieldCloseAtEightyAndOneSixtyAndNewNativeDocumentCannotResurrectTheOutgoingMenu(): Unit = runBlocking {
        use("interrupted") { browser, engine, ui ->
            val tab = browser.state.value.tab!!
            val profile = browser.state.value.space!!.websiteProfile
            val session = main { engine.session(tab, profile) }
            for (wait in listOf(80L, 160L)) {
                main { if (browser.state.value.surface == BrowserSurface.FIELD) browser.dismissSurface() }
                delay(400)
                open(ui)
                val before = draws.size
                ui.click("Edit address"); mark("ADDRESS_UP_RETURNED", wait)
                await("address Field") { browser.state.value.surface == BrowserSurface.FIELD }
                delay(wait)
                mark("CLOSE_REQUEST", wait)
                main { browser.dismissSurface() }
                ui.menuAbsent(); ui.absent("Copy"); ui.absent("Find on Page")
                val stopped = draws.size
                delay(450)
                assertEquals("Outgoing menu drew again after source revocation", stopped, draws.size)
                assertTrue(draws.drop(before).any { it.frame.phase == PageMenuPhase.HANDING_OFF && it.frame.toField > 0 })
                main { assertEquals(BrowserSurface.PAGE, browser.state.value.surface); assertTrue(engine.session(tab, profile) === session) }
                main { browser.openField(newTab = false) }
                delay(250)
                assertEquals("A fresh Field revived an old menu", stopped, draws.size)
                main { browser.dismissSurface() }
                delay(400)
            }
            open(ui)
            ui.click("Edit address")
            await("last address Field") { browser.state.value.surface == BrowserSurface.FIELD }
            val native = main { checkNotNull(engine.captureExternalActivityOwner()) }
            main { engine.reload(tab.id) }
            await("new native document invalidates the original drawing owner") { main { !engine.ownsExternalActivity(native) } }
            ui.menuAbsent(); ui.absent("Find on Page")
            main { assertEquals(BrowserSurface.FIELD, browser.state.value.surface) }
            mark("NATIVE_REVOKED")
        }
    }

    private suspend fun open(ui: OwnedPageMenuTestUi) {
        latest = null
        ui.click("Page menu")
        await("real menu settled") { latest?.frame?.let { it.interactive && !it.running } == true }
    }

    private suspend fun use(kind: String, body: suspend (BrowserController, GeckoEngine, OwnedPageMenuTestUi) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(kind in setOf("land", "interrupted"))
        val ui = OwnedPageMenuTestUi(OwnedPageMenuTestUi.Case.HANDOFF)
        var completed = false
        try {
            BrowserInstrumentedTest.FixtureServer().use { server ->
                fixture.withBrowser(menuAnimations = true, menuFrames = { frame, pose, nanos ->
                    latest = Draw(frame, pose, nanos)
                    if (draws.size < 600) draws.add(checkNotNull(latest))
                    ui.frame(frame.phase.name, frame.running, frame.interactive)
                }) { browser, engine ->
                    main {
                        fixture.ownSpace(browser, "Menu field fixture")
                        browser.openUrl(server.url("/article"))
                        ui.bind {
                            val captured = browser.state.value
                            val tab = captured.tab
                            val profile = captured.space?.websiteProfile
                            val native = engine.captureExternalActivityOwner()
                            if (tab == null || profile == null || native == null || captured.privateContentBlocked) null else {
                                val current: () -> Boolean = {
                                    val state = browser.state.value
                                    !state.loading && !state.privateContentBlocked && state.surface == captured.surface &&
                                        state.surfaceEpoch == captured.surfaceEpoch && state.selectedSpaceId == captured.selectedSpaceId &&
                                        state.space?.websiteProfile == profile && state.tab?.id == tab.id && state.tab?.url == tab.url &&
                                        engine.ownsExternalActivity(native)
                                }; current
                            }
                        }
                    }
                    await("owned article ready") { browser.state.value.page.let { !it.loading && it.progress >= 1f && it.title == "Delivery to Oslo" } }
                    try { body(browser, engine, ui) }
                    finally { ui.finish(false) }
                }
            }
            completed = true
        } finally {
            ui.finish(completed)
            receipt(kind, completed)
        }
    }

    private fun mark(name: String, requestedWait: Long? = null) {
        require(name in setOf("ADDRESS_CALL", "ADDRESS_UP_RETURNED", "CLOSE_REQUEST", "FIELD_REMAINS", "NATIVE_REVOKED"))
        check(milestones.length() < 20)
        milestones.put(JSONObject().put("event", name).put("uptimeNanos", System.nanoTime())
            .put("requestedWaitMillis", requestedWait ?: JSONObject.NULL))
    }
    private fun receipt(kind: String, completed: Boolean) {
        val rows = JSONArray()
        draws.take(600).forEach { row -> rows.put(JSONObject().put("phase", row.frame.phase.name)
            .put("uptimeNanos", row.nanos).put("toField", row.frame.toField).put("menuInteractive", row.frame.interactive)
            .put("row", JSONArray(listOf(row.pose.row.x, row.pose.row.y, row.pose.row.width, row.pose.row.height)))
            .put("measuredField", row.pose.measuredField?.let { JSONArray(listOf(it.x, it.y, it.width, it.height)) } ?: JSONObject.NULL)) }
        val folder = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "instrumentation/menu-field").apply {
            check(isDirectory || mkdirs())
        }
        File(folder, "$kind.json").writeText(JSONObject().put("completed", completed).put("componentAnimatorOverride", true)
            .put("globalAnimatorSettingsChanged", false).put("actualNativeGeckoOwner", true).put("sourceMilestones", milestones)
            .put("drawCallbacksAreNotPresentedFrames", true).put("pairedFrameParityVerified", false)
            .put("frameCadenceVerified", false).put("physicalDeviceSmoothnessVerified", false).put("draws", rows).toString())
    }
    private suspend fun await(reason: String, condition: suspend () -> Boolean) {
        val deadline = System.nanoTime() + 15_000_000_000L
        while (!condition()) { check(System.nanoTime() < deadline) { "Timed out: $reason" }; delay(16) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
}

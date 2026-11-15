package dev.yab.browser

import android.content.ClipboardManager
import android.content.Context
import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import dev.yab.browser.ui.PageMenuFrame
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.mozilla.geckoview.GeckoView

/** Shipped menu + actual Gecko owner. Functional integration, not presented-frame parity. */
@RunWith(AndroidJUnit4::class)
class BrowserPageMenuIntegrationDeviceTest {
    private val fixture = BrowserInstrumentedTest()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val menuFrames = CopyOnWriteArrayList<PageMenuFrame>()
    @Volatile private var currentMenuFrame: PageMenuFrame? = null

    @Test(timeout = 180_000)
    fun capturedMenuKeepsAndCopiesThenRunsFindOnlyAfterLandingOnTheSameNativeSession(): Unit = runBlocking {
        requireOwnedDevice()
        var completed = false
        var originalSessionRetained = false
        var nativeHiddenUnderMenu = false
        var nativeRestoredAfterMenu = false
        val ui = OwnedPageMenuTestUi(OwnedPageMenuTestUi.Case.INTEGRATION_FUNCTIONAL)
        try {
            BrowserInstrumentedTest.FixtureServer().use { server ->
                var view: GeckoView? = null
                fixture.withBrowser(viewBound = { view = it }, menuFrames = { frame, _, _ ->
                    currentMenuFrame = frame
                    ui.frame(frame.phase.name, frame.running, frame.interactive)
                    if (menuFrames.size < 300) menuFrames.add(frame)
                }) { browser, engine ->
                    main { ui.bind {
                        val source = browser.state.value
                        val tab = source.tab
                        val profile = source.space?.websiteProfile
                        val native = engine.captureExternalActivityOwner()
                        if (tab == null || profile == null || native == null || source.privateContentBlocked) null else {
                            val current: () -> Boolean = {
                                val live = browser.state.value
                                !live.loading && !live.privateContentBlocked && live.surface == source.surface &&
                                    live.surfaceEpoch == source.surfaceEpoch && live.selectedSpaceId == source.selectedSpaceId &&
                                    live.space?.websiteProfile == profile && live.tab?.id == tab.id && live.tab?.url == tab.url &&
                                    engine.ownsExternalActivity(native)
                            }; current
                        }
                    } }
                    try {
                        main { fixture.ownSpace(browser, "Menu integration"); browser.openUrl(server.url("/article")) }
                        ready(browser, "Delivery to Oslo")
                        val tab = browser.state.value.tab!!
                        val profile = browser.state.value.space!!.websiteProfile
                        val session = main { engine.session(tab, profile) }
                        currentMenuFrame = null
                        ui.click("Page menu")
                        ui.visible("Keep")
                        await("real native Menu settled") { currentMenuFrame?.let { it.interactive && !it.running } == true }
                        await("native accessibility hidden under retained menu") {
                            view?.importantForAccessibility == View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                        }
                        nativeHiddenUnderMenu = true
                        ui.click("Keep")
                        await("Keep updates only original tab") { browser.state.value.tab?.let { it.id == tab.id && it.place == TabPlace.KEPT } == true }
                        ui.visible("Kept")
                        ui.click("Copy Link")
                        val clipboard = instrumentation.targetContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        assertEquals(tab.url, main { clipboard.primaryClip?.getItemAt(0)?.text?.toString() })
                        assertSame(session, main { engine.session(browser.state.value.tab!!, profile) })
                        ui.click("Find on Page")
                        await("queued Find runs after retained menu release") { browser.state.value.find?.tab == tab.id }
                        ui.menuAbsent(); ui.absent("Kept")
                        ui.visible("Find on Page"); ui.visible("Close Find")
                        await("native accessibility restored after landed action") { view?.importantForAccessibility == View.IMPORTANT_FOR_ACCESSIBILITY_AUTO }
                        nativeRestoredAfterMenu = true
                        originalSessionRetained = main { engine.session(browser.state.value.tab!!, profile) === session }
                        assertTrue(originalSessionRetained)
                        main { browser.dismissFind() }
                    } finally { ui.finish(false) }
                }
            }
            completed = true
        } finally {
            ui.finish(completed)
            receipt("functional", completed, originalSessionRetained, nativeHiddenUnderMenu, nativeRestoredAfterMenu)
        }
    }

    @Test(timeout = 180_000)
    fun sameUrlNativeReloadAndPrivateLockRemoveTheOriginalMenuBeforeAnyReplacementAction(): Unit = runBlocking {
        requireOwnedDevice()
        var completed = false
        var originalSessionRetained = false
        var nativeHiddenUnderMenu = false
        var nativeRestoredAfterMenu = false
        val ui = OwnedPageMenuTestUi(OwnedPageMenuTestUi.Case.INTEGRATION_REVOCATION)
        try {
            BrowserInstrumentedTest.FixtureServer().use { server ->
                var view: GeckoView? = null
                fixture.withBrowser(viewBound = { view = it }, menuFrames = { frame, _, _ ->
                    currentMenuFrame = frame
                    ui.frame(frame.phase.name, frame.running, frame.interactive)
                    if (menuFrames.size < 300) menuFrames.add(frame)
                }) { browser, engine ->
                    main { ui.bind {
                        val source = browser.state.value
                        val tab = source.tab
                        val profile = source.space?.websiteProfile
                        val native = engine.captureExternalActivityOwner()
                        if (tab == null || profile == null || native == null || source.privateContentBlocked) null else {
                            val current: () -> Boolean = {
                                val live = browser.state.value
                                !live.loading && !live.privateContentBlocked && live.surface == source.surface &&
                                    live.surfaceEpoch == source.surfaceEpoch && live.selectedSpaceId == source.selectedSpaceId &&
                                    live.space?.websiteProfile == profile && live.tab?.id == tab.id && live.tab?.url == tab.url &&
                                    engine.ownsExternalActivity(native)
                            }; current
                        }
                    } }
                    try {
                        main { fixture.ownSpace(browser, "Menu revocation"); browser.openUrl(server.url("/second")) }
                        ready(browser, "Second document")
                        val tab = browser.state.value.tab!!
                        val profile = browser.state.value.space!!.websiteProfile
                        val original = main { checkNotNull(engine.captureExternalActivityOwner()) }
                        val session = main { engine.session(tab, profile) }
                        currentMenuFrame = null
                        ui.click("Page menu")
                        ui.visible("Keep")
                        await("real native Menu settled") { currentMenuFrame?.let { it.interactive && !it.running } == true }
                        main { engine.reload(tab.id) }
                        await("same URL native document revokes captured owner") { !engine.ownsExternalActivity(original) }
                        ui.menuAbsent(); ui.absent("Share"); ui.absent("Find on Page")
                        assertEquals(TabPlace.TODAY, browser.state.value.tab!!.place)
                        ready(browser, "Second document")
                        originalSessionRetained = main { engine.session(tab, profile) === session }
                        assertTrue(originalSessionRetained)
                        await("native accessibility restored after document revoke") { view?.importantForAccessibility == View.IMPORTANT_FOR_ACCESSIBILITY_AUTO }
                        nativeRestoredAfterMenu = true

                        main { browser.openUrl(server.url("/article"), privately = true); browser.unlockPrivate(true) }
                        ready(browser, "Delivery to Oslo")
                        currentMenuFrame = null
                        ui.click("Page menu")
                        ui.visible("Share")
                        await("real native Private Menu settled") { currentMenuFrame?.let { it.interactive && !it.running } == true }
                        // Private pages intentionally omit persistence controls.
                        // Absence, rather than a disabled public-page tile, is the
                        // current shipped privacy boundary.
                        ui.absent("Keep"); ui.absent("Kept")
                        assertEquals(TabPlace.TODAY, browser.state.value.tab!!.place)
                        await("Private native accessibility hidden under retained menu") {
                            view?.importantForAccessibility == View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                        }
                        nativeHiddenUnderMenu = true
                        main { browser.lockPrivate() }
                        ui.menuAbsent(); ui.absent("Share"); ui.absent("Find on Page")
                        assertTrue(browser.state.value.privateContentBlocked)
                        ui.absent("Find on Page")
                        assertFalse(browser.publicSnapshot().toString().contains(server.url("/article")))
                    } finally { ui.finish(false) }
                }
            }
            completed = true
        } finally {
            ui.finish(completed)
            receipt("revocation", completed, originalSessionRetained, nativeHiddenUnderMenu, nativeRestoredAfterMenu)
        }
    }

    private fun requireOwnedDevice() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
    }
    private suspend fun ready(browser: BrowserController, title: String) {
        await("owned native page ready") { browser.state.value.page.let { !it.loading && it.progress >= 1f && it.title == title } }
    }
    private suspend fun await(name: String, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + 30_000_000_000L
        while (!main(predicate)) { check(System.nanoTime() < deadline) { "Timed out: $name" }; delay(25) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    private fun receipt(case: String, completed: Boolean, retained: Boolean, hidden: Boolean, restored: Boolean) {
        require(case in setOf("functional", "revocation"))
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }
        File(folder, "page-menu-integration-$case.json").writeText(JSONObject().put("completed", completed)
            .put("productionMenuIntegration", true).put("controlledLoopbackFixture", true).put("originalSessionRetained", retained)
            .put("nativeHiddenUnderMenu", hidden).put("nativeRestoredAfterMenu", restored)
            .put("pairedIosPresentedFrames", false).put("realProviderAcceptance", false)
            .put("composeTestClockInstalled", false).put("drawCallbacks", menuFrames.size)
            .put("phase", currentMenuFrame?.phase?.name ?: "NONE")
            .put("running", currentMenuFrame?.running ?: false)
            .put("interactive", currentMenuFrame?.interactive ?: false).toString())
    }
}

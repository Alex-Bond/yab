package dev.yab.browser

import android.content.ClipboardManager
import android.content.Context
import android.os.SystemClock
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference
import org.mozilla.geckoview.GeckoView
import org.json.JSONArray
import org.json.JSONObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Disposable, loopback-only Gecko pages and the shipped Compose controls. No external accounts. */
@RunWith(AndroidJUnit4::class)
class BrowserActionsDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val fixture = BrowserInstrumentedTest()
    private val nativeFind = CopyOnWriteArrayList<JSONObject>()

    @Test(timeout = 240_000)
    fun nativeFindCountsStepsWrapsOptionsClearsAndRevokesAcrossDocumentAndPrivateLock(): Unit = runBlocking {
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.ACTIONS_FIND)
        ui.run {
            ownedDevice()
            BrowserInstrumentedTest.FixtureServer().use { server ->
                val boundView = AtomicReference<GeckoView?>()
                fixture.withBrowser(viewBound = { boundView.set(it) }) { browser, engine ->
                    main {
                        ui.bind(browser, engine)
                        engine.findObserver = { row ->
                            if (nativeFind.size < 64) nativeFind += JSONObject().put("stage", row.stage.name)
                                .put("ownerCurrent", row.ownerCurrent).put("entryCurrent", row.entryCurrent)
                                .put("alive", row.alive).put("documentCurrent", row.documentCurrent)
                                .put("sessionOwned", row.sessionOwned).put("queryMatches", row.queryMatches ?: JSONObject.NULL)
                                .put("current", row.current ?: JSONObject.NULL).put("total", row.total ?: JSONObject.NULL)
                                .put("nativeReadiness", row.readiness?.let { native -> JSONObject()
                                    .put("privateProfile", native.privateProfile).put("privatePaused", native.privatePaused)
                                    .put("foreground", native.foreground).put("sessionOpen", native.sessionOpen)
                                    .put("viewPresent", native.viewPresent).put("viewAttached", native.viewAttached)
                                    .put("viewShown", native.viewShown).put("viewFocused", native.viewFocused)
                                    .put("viewSessionCurrent", native.viewSessionCurrent).put("viewHasSize", native.viewHasSize)
                                    .put("firstPaint", native.firstPaint).put("pageStopped", native.pageStopped)
                                    .put("contentBound", native.contentBound).put("bridgeConnected", native.bridgeConnected)
                                } ?: JSONObject.NULL)
                        }
                    }
                    ui.checkpoint("browser_ready")
                    main { fixture.ownSpace(browser, "Native Find"); browser.openUrl(server.url("/article")) }
                    ready(browser, "Delivery to Oslo")
                    val page = browser.state.value.tab!!
                    ui.requireOwnCurrent()
                    compose.onNodeWithContentDescription("Page menu").performClick()
                    ui.requireOwnCurrent()
                    compose.onNodeWithText("Find on Page").performClick()
                    ui.requireOwnCurrent()
                    compose.onNodeWithTag("browser.find.query").performTextReplacement("delivery city")
                    result(browser, 1, 16)
                    compose.onNodeWithTag("browser.find.count").assertTextEquals("1 of 16")
                    compose.onNodeWithContentDescription("Back").assertDoesNotExist()
                    ui.requireOwnCurrent()
                    compose.onNodeWithContentDescription("Next Match").performClick()
                    result(browser, 2, 16)
                    ui.requireOwnCurrent()
                    compose.onNodeWithContentDescription("Previous Match").performClick()
                    result(browser, 1, 16)
                    ui.requireOwnCurrent()
                    compose.onNodeWithContentDescription("Previous Match").performClick()
                    result(browser, 16, 16)
                    assertTrue(browser.state.value.find!!.result.wrapped)
                    fixture.shot("find-native-last-match.png")

                    ui.requireOwnCurrent()
                    compose.onNodeWithTag("browser.find.query").performTextReplacement("Delivery city")
                    // SessionFinder starts a changed query at the current selection. The
                    // preceding backwards wrap selected match 16; clear removes highlights,
                    // not that native anchor. Case/options checks must retain the exact
                    // count and a valid native ordinal, without inventing a jump to match 1.
                    result(browser, null, 16)
                    ui.requireOwnCurrent()
                    compose.onNodeWithText("Options").performClick()
                    ui.requireOwnCurrent()
                    compose.onNodeWithText("Match Case").performClick()
                    result(browser, 0, 0)
                    compose.onNodeWithText("No matches").assertIsDisplayed()
                    compose.onNodeWithContentDescription("Next Match").assertIsNotEnabled()
                    ui.requireOwnCurrent()
                    compose.onNodeWithText("Options").performClick()
                    ui.requireOwnCurrent()
                    compose.onNodeWithText("Match Case").performClick()
                    result(browser, null, 16)
                    ui.requireOwnCurrent()
                    compose.onNodeWithTag("browser.find.query").performTextReplacement("cit")
                    result(browser, null, 16)
                    ui.requireOwnCurrent()
                    compose.onNodeWithText("Options").performClick()
                    ui.requireOwnCurrent()
                    compose.onNodeWithText("Whole Words").performClick()
                    result(browser, 0, 0)
                    // The native result may arrive before the popup's exit finishes.
                    // Admit the next real touch only after that window has left.
                    compose.waitUntil(5_000) {
                        compose.onAllNodesWithText("Whole Words").fetchSemanticsNodes().isEmpty()
                    }
                    compose.waitForIdle()
                    ui.requireOwnCurrent()
                    compose.onNodeWithContentDescription("Clear Find").performClick()
                    await("empty native search") { browser.state.value.find?.let { it.query.text.isEmpty() && !it.searching && it.result.total == 0 } == true }
                    compose.onNodeWithContentDescription("Next Match").assertIsNotEnabled()
                    ui.requireOwnCurrent()
                    compose.onNodeWithContentDescription("Close Find").performClick()
                    compose.onNodeWithTag("browser.find.query").assertDoesNotExist()
                    compose.onNodeWithContentDescription("Page menu").assertIsDisplayed()
                    fixture.shot("find-native-cleared.png")
                    assertEquals(page.id, browser.state.value.tab!!.id)

                    // A navigation, including its native session document generation, revokes the bar.
                    main { browser.beginFind("delivery city"); browser.openUrl(server.url("/second"), newTab = false) }
                    ready(browser, "Second document")
                    assertNull(browser.state.value.find)
                    main { browser.beginFind("Second document") }
                    await("replacement document's native matches") { browser.state.value.find?.let { !it.searching && it.result.total > 0 } == true }
                    main { engine.reload(page.id) }
                    await("same-URL native reload revokes Find") { browser.state.value.find == null }
                    ready(browser, "Second document")

                    main { browser.openUrl(server.url("/article"), privately = true); browser.unlockPrivate(true) }
                    ready(browser, "Delivery to Oslo")
                    // Native content can finish before the test-owned Compose clock has
                    // drawn the replacement Private view. Complete that UI transaction,
                    // then require its real display/session before exercising Find.
                    compose.waitForIdle()
                    compose.onNodeWithContentDescription("Page menu").assertIsDisplayed()
                    ui.requireOwnCurrent()
                    main {
                        val privateState = browser.state.value
                        val privateTab = checkNotNull(privateState.tab)
                        val privateProfile = checkNotNull(privateState.space).websiteProfile
                        check(privateProfile.isPrivate && !privateState.privateContentBlocked)
                        val native = checkNotNull(boundView.get())
                        assertSame(engine.session(privateTab, privateProfile), native.session)
                        check(native.isAttachedToWindow && native.isShown && native.hasWindowFocus() && native.width > 0 && native.height > 0)
                        browser.beginFind("delivery city")
                    }
                    result(browser, 1, 16)
                    assertFalse(browser.publicSnapshot().toString().contains("delivery city"))
                    main { browser.lockPrivate() }
                    assertNull(browser.state.value.find)
                    compose.onNodeWithTag("browser.find.query").assertDoesNotExist()
                }
            }
        }
    }

    @Test(timeout = 120_000)
    fun pinnedHeldMenuCopiesAndClosesThePinWithUndoAndNeverOffersKeep(): Unit = runBlocking {
        val ui = OwnedBrowserTestUi(OwnedBrowserTestUi.Case.ACTIONS_PIN)
        ui.run {
            ownedDevice()
            BrowserInstrumentedTest.FixtureServer().use { server ->
                fixture.withBrowser { browser, engine ->
                    main { ui.bind(browser, engine) }
                    ui.checkpoint("browser_ready")
                    main { fixture.ownSpace(browser, "Pin actions"); browser.openUrl(server.url("/second")) }
                    ready(browser, "Second document")
                    val front = browser.state.value.tab!!.id
                    val pin = BrowserTab("held-pin", server.url("/article"), "Pinned article", TabPlace.PINNED, createdAt = 1)
                    main {
                        val snapshot = browser.publicSnapshot()!!
                        browser.applySyncedSnapshot(snapshot.copy(spaces = snapshot.spaces.map { space ->
                            if (space.id == browser.state.value.selectedSpaceId) space.copy(tabs = listOf(pin) + space.tabs) else space
                        }))
                        browser.show(BrowserSurface.SPACES)
                    }
                    ui.requireOwnCurrent()
                    compose.onNodeWithTag("browser.pin.${pin.id}").performTouchInput { longClick() }
                    compose.onNodeWithText("Copy Link").assertIsDisplayed()
                    compose.onNodeWithText("Share").assertIsDisplayed()
                    compose.onNodeWithText("Close Tab").assertIsDisplayed()
                    compose.onNodeWithText("Keep").assertDoesNotExist()
                    compose.onNodeWithText("Unkeep").assertDoesNotExist()
                    ui.requireOwnCurrent()
                    compose.onNodeWithText("Copy Link").performClick()
                    val clipboard = InstrumentationRegistry.getInstrumentation().targetContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    ui.checkpoint("before_clipboard_read")
                    ui.requireOwnCurrent()
                    assertEquals(pin.url, main { clipboard.primaryClip?.getItemAt(0)?.text?.toString() })
                    ui.requireOwnCurrent()
                    compose.onNodeWithTag("browser.pin.${pin.id}").performTouchInput { longClick() }
                    ui.requireOwnCurrent()
                    compose.onNodeWithText("Close Tab").performClick()
                    assertTrue(browser.state.value.space!!.tabs.none { it.id == pin.id })
                    assertEquals(front, browser.state.value.tab!!.id)
                    assertTrue(browser.state.value.undoAvailable)
                    main { browser.undoClose() }
                    await("closed pin restored by Undo") { browser.state.value.space!!.tabs.any { it.id == pin.id && it.place == TabPlace.PINNED } }
                    assertEquals(front, browser.state.value.tab!!.id)
                }
            }
        }
    }

    private fun ownedDevice() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true") { "Requires the disposable runner device" }
    }
    private suspend fun result(browser: BrowserController, current: Int?, total: Int) {
        try {
            await("native Find ordinal and count") { browser.state.value.find?.let {
                !it.searching && !it.failed && it.result.total == total &&
                    (if (current != null) it.result.current == current else it.result.current in 1..total)
            } == true }
        } catch (failure: Throwable) {
            // Capture while this exact browser is still alive. The outer fixture's teardown
            // deliberately dismisses Find, so a later diagnostic cannot explain this result.
            runCatching {
                val state = browser.state.value
                val find = state.find
                val folder = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "instrumentation")
                if (folder.isDirectory || folder.mkdirs()) File(folder, "browser-find-native-failure.json").writeText(
                    JSONObject().put("schema", 1).put("expectedCurrent", current ?: JSONObject.NULL).put("expectedTotal", total)
                        .put("acceptNativeSelectedOrdinal", current == null)
                        .put("findPresent", find != null).put("searching", find?.searching).put("failed", find?.failed)
                        .put("current", find?.result?.current).put("total", find?.result?.total).put("wrapped", find?.result?.wrapped)
                        .put("queryLength", find?.query?.text?.length).put("matchCase", find?.query?.matchCase)
                        .put("wholeWord", find?.query?.wholeWord).put("surface", state.surface.name)
                        .put("privateBlocked", state.privateContentBlocked).put("pageLoading", state.page.loading)
                        .put("nativeFind", JSONArray(nativeFind.take(64))).toString(2))
            }
            throw failure
        }
    }
    private suspend fun ready(browser: BrowserController, title: String) {
        await("owned page ready") { browser.state.value.page.let { !it.loading && it.progress >= 1f && it.title == title } }
    }
    private suspend fun await(name: String, predicate: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + 30_000
        while (!predicate()) { check(SystemClock.elapsedRealtime() < until) { "Timed out waiting for $name" }; delay(50) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
}

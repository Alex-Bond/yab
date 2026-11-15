package dev.yab.browser

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.material3.Text
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import androidx.test.platform.app.InstrumentationRegistry

/** Actual full Field consumer on an explicitly controlled Compose clock/local animation seam.
 * Captures app pixels only; it does not measure OS IME, presented-frame cadence or iOS parity. */
class BrowserFieldPrivateDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private val input get() = compose.onNodeWithTag("browser.field.pill")
    private val pages get() = compose.onNodeWithTag("browser.field.pages")
    private fun ink() = input.fetchSemanticsNode().config[FieldPrivateInkKey]
    private fun position() = pages.fetchSemanticsNode().config[FieldPagesPositionKey]

    @Test fun fullFieldEyesReverseAt80And160WithoutReplacingThePagesOrSnappingTheTint() = fixture { browser, _ ->
        compose.mainClock.autoAdvance = false
        compose.runOnIdle { browser.openField() }
        compose.mainClock.advanceTimeBy(600)
        val initial = position()
        for (delay in listOf(80L, 160L)) {
            compose.onNodeWithContentDescription("Search privately").performClick()
            compose.mainClock.advanceTimeByFrame(); compose.mainClock.advanceTimeByFrame()
            compose.mainClock.advanceTimeBy(delay)
            val reversal = compose.onNodeWithContentDescription("Turn off private input")
            val node = reversal.fetchSemanticsNode().id
            val owner = compose.runOnIdle { checkNotNull(browser.captureFieldInput()) }
            // Android performClick includes a default 16 ms MOVE and advances even a
            // paused mainClock. Finish that real press interval before latching the
            // pre-UP drawing; UP itself adds no event time and is the target change.
            reversal.performTouchInput { down(center); move() }
            var pressed = true
            var failure: Throwable? = null
            try {
                shot("private-entering-$delay.png")
                val enteringInk = ink(); val enteringPage = position()
                assertTrue("Coupled tint did not move", enteringInk > 0f && enteringInk < 1f)
                assertTrue("Retained pager did not move toward Private", enteringPage < initial && enteringPage > 0f)
                compose.onNodeWithText("PRIVATE-LIST-CANARY").assertDoesNotExist()
                assertEquals("The original pressed Eyes node was replaced", node, reversal.fetchSemanticsNode().id)
                compose.runOnIdle { assertTrue(browser.fieldInputCurrent(owner)) }
                val beforeUp = compose.mainClock.currentTime
                reversal.performTouchInput { up() }; pressed = false
                assertEquals("UP advanced the controlled observation clock", beforeUp, compose.mainClock.currentTime)
                compose.waitForIdle()
                assertEquals(enteringInk, ink(), .001f)
                assertEquals(enteringPage, position(), .001f)
            } catch (error: Throwable) { failure = error; throw error }
            finally {
                if (pressed) {
                    runCatching {
                        compose.runOnIdle { assertTrue(browser.fieldInputCurrent(owner)) }
                        assertEquals(node, reversal.fetchSemanticsNode().id)
                        reversal.performTouchInput { cancel(delayMillis = 0) }
                    }.exceptionOrNull()?.let { cleanup -> failure?.addSuppressed(cleanup) ?: throw cleanup }
                }
            }
            compose.mainClock.advanceTimeBy(800)
            assertEquals(0f, ink(), .001f)
            assertEquals(initial, position(), .001f)
            assertFalse(browser.state.value.fieldIsPrivate)
            assertTrue(browser.state.value.privateLocked)
        }
        compose.mainClock.autoAdvance = true
    }

    @Test fun unlockIsInPlaceAndFirstLockFrameOrPrivacyABARemovesPrivateWords() = fixture { browser, replies ->
        compose.mainClock.autoAdvance = false
        compose.runOnIdle { browser.openField(privately = true) }
        compose.mainClock.advanceTimeBy(600)
        compose.onNodeWithText("PRIVATE-LIST-CANARY").assertDoesNotExist()
        compose.onNodeWithTag("browser.field.private.unlock").performClick()
        compose.mainClock.advanceTimeBy(220)
        assertEquals(FieldPrivatePhase.TRYING.ordinal.toFloat(), privatePose()[0], 0f)
        assertEquals(0f, privatePose()[4], 0f)
        compose.runOnIdle { assertEquals(1, replies.size); replies[0](true) }
        compose.mainClock.advanceTimeBy(200)
        compose.onNodeWithText("PRIVATE-LIST-CANARY").assertDoesNotExist()
        assertTrue(browser.state.value.fieldIsPrivate)
        assertFalse(browser.state.value.privateLocked)
        compose.mainClock.advanceTimeBy(1100)
        compose.onNodeWithText("PRIVATE-LIST-CANARY").assertIsDisplayed()
        shot("private-unlocked-list.png")
        val stalePick = originalRenderedClick(compose.onNodeWithText("PRIVATE-LIST-CANARY").fetchSemanticsNode())
        compose.runOnIdle {
            val originalTab = browser.state.value.tab?.id
            browser.lockPrivate()
            // Even before recomposition, a retained accessibility callback has no
            // authority to open the private row after the native lock changes.
            stalePick()
            assertEquals(originalTab, browser.state.value.tab?.id)
            assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
            assertTrue(browser.state.value.privateLocked)
        }
        // This clock is paused. Observe the first recomposed frame, with no fade
        // or settling interval in which a private label could remain available.
        compose.mainClock.advanceTimeByFrame()
        compose.waitForIdle()
        compose.onNodeWithText("PRIVATE-LIST-CANARY").assertDoesNotExist()
        assertEquals(0f, privatePose()[4], 0f)
        shot("private-relocked.png")
        compose.onNodeWithTag("browser.field.private.unlock").performClick()
        compose.runOnIdle { assertEquals(2, replies.size); browser.fieldPrivacy(false); browser.fieldPrivacy(true) }
        compose.mainClock.advanceTimeBy(800)
        compose.runOnIdle { replies[1](true) }
        compose.mainClock.advanceTimeBy(1100)
        assertTrue(browser.state.value.privateLocked)
        compose.onNodeWithText("PRIVATE-LIST-CANARY").assertDoesNotExist()
        compose.runOnIdle { browser.invalidateLocalOwnership() }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithTag("browser.field.motion").assertDoesNotExist()
        compose.mainClock.autoAdvance = true
    }

    @Test fun chatsQueryKeepsItsPageAndReturnOnlyRestsTheKeyboard() = fixture(chats = true) { browser, _ ->
        compose.runOnIdle { browser.openField() }
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Chats").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("field-chats-fixture").assertIsDisplayed()
        compose.onNodeWithTag("browser.field.input").performTextReplacement("2+2")
        compose.onNodeWithTag("field-chats-fixture").assertTextEquals("2+2")
        compose.onNodeWithText("Search Google").assertDoesNotExist()
        compose.onNodeWithTag("browser.field.answer").assertDoesNotExist()
        compose.onNodeWithTag("browser.field.math.+").assertDoesNotExist()
        compose.onNodeWithTag("browser.field.input").performImeAction()
        compose.waitForIdle()
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        assertEquals("2+2", browser.state.value.fieldText)
        assertTrue(browser.state.value.fieldResting)
        assertFalse(browser.state.value.fieldIsPrivate)
        compose.onNodeWithTag("field-chats-fixture").assertIsDisplayed()
    }

    private fun privatePose() = compose.onNodeWithTag("browser.field.private.page").fetchSemanticsNode().config[FieldPrivatePoseKey]

    private fun fixture(chats: Boolean = false, body: (BrowserController, MutableList<(Boolean) -> Unit>) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val public = BrowserTab("field-private-public", "https://field-private.invalid/", "Public page", createdAt = 1)
        val space = BrowserSpace("field-private-space", "Personal", tabs = listOf(public), currentTabId = public.id)
        val repository = object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)
            override suspend fun save(snapshot: BrowserSnapshot) = Unit
        }
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) = Unit
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) = Unit
            override fun goBack(tabId: String) = Unit
            override fun goForward(tabId: String) = Unit
            override fun reload(tabId: String) = Unit
            override fun stop(tabId: String) = Unit
            override fun close(tabId: String) = Unit
            override suspend fun clearWebsiteData(profileIds: Set<String>) = Unit
        }
        lateinit var browser: BrowserController
        compose.runOnIdle { browser = BrowserController(repository, engine, scope) }
        compose.waitUntil(5000) { !browser.state.value.loading }
        val replies = mutableListOf<(Boolean) -> Unit>()
        compose.runOnIdle {
            browser.openUrl("https://private-field.invalid/", privately = true)
            browser.unlockPrivate(true)
            val tab = browser.state.value.tab!!
            browser.pageChanged(tab.id, EnginePageState(url = tab.url, title = "PRIVATE-LIST-CANARY", progress = 1f))
            browser.selectSpace(space.id)
        }
        compose.setContent {
            CompositionLocalProvider(LocalFieldPageAnimationsEnabled provides true) {
                BrowserScreen(browser, modifier = Modifier.testTag("field-private-scene"), onUnlockPrivate = { replies += it },
                    onAskQuestion = { _, _ -> error("Chats search must not invoke inference") },
                    onOpenChats = if (chats) ({}) else null,
                    fieldChatsContent = if (chats) ({ modifier, _ ->
                        val current by browser.state.collectAsState()
                        Text(current.fieldText, modifier.testTag("field-chats-fixture"))
                    }) else null) { _, _, _ -> }
            }
        }
        try { body(browser, replies) }
        finally { compose.mainClock.autoAdvance = true; compose.runOnIdle { scope.cancel() } }
    }

    private fun shot(name: String) {
        check(name in setOf("private-entering-80.png", "private-entering-160.png", "private-unlocked-list.png", "private-relocked.png"))
        val bitmap = compose.onNodeWithTag("field-private-scene").captureToImage().asAndroidBitmap()
        try {
            val folder = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "instrumentation/field-private-controlled")
            check(folder.isDirectory || folder.mkdirs())
            folder.resolve(name).outputStream().use { check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
        } finally { bitmap.recycle() }
    }
}

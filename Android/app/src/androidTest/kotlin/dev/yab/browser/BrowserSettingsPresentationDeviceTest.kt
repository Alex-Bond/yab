package dev.yab.browser

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TestName
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Production Settings consumer on an explicit controlled Compose clock, RAM profile and inert
 * engine. This is not native OS animation/IME, presented cadence or paired iOS pixel evidence. */
class BrowserSettingsPresentationDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    @get:Rule val testName = TestName()
    private val sheet get() = compose.onNodeWithTag("settings.motion")
    private fun offset() = sheet.fetchSemanticsNode().config[SettingsOffsetKey]
    private fun activate(node: SemanticsNodeInteraction) = node.performSemanticsAction(SemanticsActions.OnClick) { it() }

    @Test fun entryRetainsTheRootQueryWhileAPagePushIsReversedThroughTheRealHeader() = fixture { browser ->
        compose.runOnIdle { browser.show(BrowserSurface.SETTINGS) }
        compose.mainClock.advanceTimeBy(250)
        assertTrue(offset() > 0f && offset() < 1f)
        compose.mainClock.advanceTimeBy(450)
        assertEquals(0f, offset(), .001f)
        compose.onNodeWithTag("settings.search").performTextReplacement("appearance")
        activate(compose.onNodeWithText("Appearance"))
        compose.mainClock.advanceTimeBy(96)
        val page = compose.onNodeWithTag("settings.route.1")
        val entering = page.fetchSemanticsNode().config[SettingsRouteXKey]
        assertTrue(entering > 0f && entering < 1f)
        compose.onNodeWithTag("settings.search").assertDoesNotExist()
        activate(compose.onNodeWithContentDescription("Back"))
        compose.mainClock.advanceTimeBy(450)
        compose.onNodeWithTag("settings.search").assertTextEquals("appearance")
        compose.onNodeWithTag("settings.route.1").assertDoesNotExist()
        assertEquals(BrowserSurface.SETTINGS, browser.state.value.surface)
    }

    @Test fun anOutgoingRouteCannotRunItsCapturedToggleOrReviveItAfterReopenAndBackground() = fixture { browser ->
        compose.runOnIdle { browser.show(BrowserSurface.SETTINGS) }
        compose.mainClock.advanceTimeBy(700)
        activate(compose.onNodeWithText("General"))
        compose.mainClock.advanceTimeBy(550)
        val staleToggle = dev.yab.browser.originalRenderedClick(compose.onNodeWithText("Swipe from Anywhere").fetchSemanticsNode())
        val old = compose.runOnIdle { browser.captureSettingsPresentation()!! }
        val before = browser.state.value.settings.swipeAnywhere
        compose.runOnIdle {
            assertTrue(browser.dismissSettings(old))
            staleToggle()
            assertEquals(before, browser.state.value.settings.swipeAnywhere)
        }
        compose.mainClock.advanceTimeBy(150)
        sheet.assertExists()
        compose.onNodeWithText("Swipe from Anywhere").assertDoesNotExist()
        compose.runOnIdle { browser.show(BrowserSurface.SETTINGS); staleToggle() }
        compose.mainClock.advanceTimeBy(700)
        // Interrupted close keeps its route, but its old action generation stays revoked.
        compose.runOnIdle { staleToggle(); assertEquals(before, browser.state.value.settings.swipeAnywhere) }
        val fresh = dev.yab.browser.originalRenderedClick(compose.onNodeWithText("Swipe from Anywhere").fetchSemanticsNode())
        compose.runOnIdle { fresh(); assertEquals(!before, browser.state.value.settings.swipeAnywhere) }
        compose.runOnIdle { browser.backgrounded(); fresh() }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Swipe from Anywhere").assertDoesNotExist()
        assertEquals(!before, browser.state.value.settings.swipeAnywhere)
        compose.runOnIdle { browser.foregrounded(); fresh() }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Swipe from Anywhere").assertIsDisplayed()
        assertEquals(!before, browser.state.value.settings.swipeAnywhere)
        activate(compose.onNodeWithText("Swipe from Anywhere"))
        assertEquals(before, browser.state.value.settings.swipeAnywhere)
        val shortBackground = dev.yab.browser.originalRenderedClick(compose.onNodeWithText("Swipe from Anywhere").fetchSemanticsNode())
        compose.runOnIdle { browser.backgrounded(); browser.foregrounded(); shortBackground() }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Swipe from Anywhere").assertIsDisplayed()
        assertEquals(before, browser.state.value.settings.swipeAnywhere)
        activate(compose.onNodeWithText("Swipe from Anywhere"))
        assertEquals(!before, browser.state.value.settings.swipeAnywhere)
    }

    @Test fun foregroundRebindMakesTheRetainedRealControlTouchableWithoutAnUnrelatedStateChange() = fixture { browser ->
        compose.runOnIdle { browser.show(BrowserSurface.SETTINGS) }
        compose.mainClock.advanceTimeBy(700)
        activate(compose.onNodeWithText("General")); compose.mainClock.advanceTimeBy(550)
        val row = compose.onNodeWithText("Swipe from Anywhere")
        val stale = dev.yab.browser.originalRenderedClick(row.fetchSemanticsNode())
        val before = browser.state.value.settings.swipeAnywhere
        compose.runOnIdle {
            browser.backgrounded(); browser.foregrounded(); stale()
            assertEquals(before, browser.state.value.settings.swipeAnywhere)
        }
        // The inactive value can be conflated. No preference, navigation or manual recomposition
        // is used to wake the fresh lease; its rendered gate must become live on its own.
        compose.mainClock.advanceTimeByFrame()
        row.assertIsDisplayed().assertIsEnabled()
        row.performTouchInput { click() }
        compose.runOnIdle { assertEquals(!before, browser.state.value.settings.swipeAnywhere) }
        compose.runOnIdle { stale(); assertEquals(!before, browser.state.value.settings.swipeAnywhere) }
    }

    @Test fun committedEdgeKeepsBackUntilLandingAndHeaderBackDoesNotDismissTheWholeSheet() = fixture { browser ->
        compose.runOnIdle { browser.show(BrowserSurface.SETTINGS) }
        compose.mainClock.advanceTimeBy(700)
        activate(compose.onNodeWithText("General")); compose.mainClock.advanceTimeBy(550)
        val page = compose.onNodeWithTag("settings.route.1")
        val density = compose.activity.resources.displayMetrics.density
        val initial = page.fetchSemanticsNode()
        val originalNode = initial.id
        val lease = compose.runOnIdle { browser.captureSettingsPresentation()!! }
        var pressed = false
        var failure: Throwable? = null
        try {
            page.performTouchInput {
                down(Offset(8 * density, height * .5f)); pressed = true
                moveTo(Offset(width * .55f, height * .5f), delayMillis = 240)
            }
            compose.mainClock.advanceTimeByFrame()
            page.performTouchInput { up() }; pressed = false
            compose.mainClock.advanceTimeByFrame()
            val leaving = page.fetchSemanticsNode().config[SettingsRouteXKey]
            assertTrue("The real edge did not enter its committed flight", leaving > .5f && leaving < 1f)
            compose.onNodeWithTag("settings.search").assertDoesNotExist()
            compose.onNodeWithContentDescription("Back").assertExists()
            assertEquals(BrowserSurface.SETTINGS, browser.state.value.surface)
            // This is a fresh actual header callback during flight, not an old saved action.
            activate(compose.onNodeWithContentDescription("Back"))
            compose.mainClock.advanceTimeBy(450)
            assertEquals(BrowserSurface.SETTINGS, browser.state.value.surface)
            compose.onNodeWithTag("settings.search").assertExists()
            activate(compose.onNodeWithText("Appearance"))
            compose.mainClock.advanceTimeBy(550)
            compose.onNodeWithText("Darken Websites").assertExists()
            assertEquals(BrowserSurface.SETTINGS, browser.state.value.surface)
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            if (pressed) runCatching {
                compose.runOnIdle { assertTrue(browser.settingsActionsCurrent(lease)) }
                assertEquals(originalNode, page.fetchSemanticsNode().id)
                page.performTouchInput { cancel(delayMillis = 0) }
            }.exceptionOrNull()?.let { cleanup -> failure?.addSuppressed(cleanup) ?: throw cleanup }
        }
    }

    @Test fun lockedPrivateStillHasFreshUsableGlobalSettingsWithoutItsPageWords() = fixture { browser ->
        compose.runOnIdle {
            browser.openUrl("https://private-settings.invalid/secret", privately = true)
            val tab = browser.state.value.tab!!
            browser.pageChanged(tab.id, EnginePageState(url = tab.url, title = "PRIVATE-SETTINGS-CANARY", progress = 1f))
            browser.show(BrowserSurface.SETTINGS)
        }
        compose.mainClock.advanceTimeBy(700)
        assertTrue(browser.state.value.privateContentBlocked)
        compose.onNodeWithText("PRIVATE-SETTINGS-CANARY").assertDoesNotExist()
        activate(compose.onNodeWithText("General"))
        compose.mainClock.advanceTimeBy(550)
        val before = browser.state.value.settings.swipeAnywhere
        activate(compose.onNodeWithText("Swipe from Anywhere"))
        assertEquals(!before, browser.state.value.settings.swipeAnywhere)
        assertTrue(browser.state.value.privateContentBlocked)
        compose.onNodeWithText("PRIVATE-SETTINGS-CANARY").assertDoesNotExist()
    }

    @Test fun twoRetainedPreferenceActionsBeforeRecompositionKeepBothPropertyChanges() = fixture { browser ->
        compose.runOnIdle { browser.show(BrowserSurface.SETTINGS) }
        compose.mainClock.advanceTimeBy(700)
        activate(compose.onNodeWithText("Privacy"))
        compose.mainClock.advanceTimeBy(550)
        val lock = compose.onNodeWithText("Lock Private Tabs").fetchSemanticsNode().config[SemanticsActions.OnClick].action!!
        val history = compose.onNodeWithText("Sync History").fetchSemanticsNode().config[SemanticsActions.OnClick].action!!
        val before = browser.state.value.settings
        compose.runOnIdle {
            lock(); history()
            assertEquals(!before.lockPrivate, browser.state.value.settings.lockPrivate)
            assertEquals(!before.syncHistory, browser.state.value.settings.syncHistory)
        }
    }

    @Test fun movingHeaderKeepsRootSpaceDragAndUsesItsMeasuredFullHeightForFlick() = fixture { browser ->
        compose.runOnIdle { browser.show(BrowserSurface.SETTINGS) }
        compose.mainClock.advanceTimeBy(700)
        val density = compose.activity.resources.displayMetrics.density
        val header = compose.onNodeWithTag("settings.header")
        fun moveToRoot(point: Offset) {
            val origin = header.fetchSemanticsNode().positionInRoot
            header.performTouchInput { moveTo(point - origin) }
            compose.mainClock.advanceTimeByFrame()
        }
        fun drag() = sheet.fetchSemanticsNode().config[SettingsDragKey]
        val lease = compose.runOnIdle { browser.captureSettingsPresentation()!! }
        val originalNode = header.fetchSemanticsNode().id
        val first = header.fetchSemanticsNode().boundsInRoot.center
        header.performTouchInput { down(center) }
        var pressed = true
        var failure: Throwable? = null
        try {
            moveToRoot(first + Offset(0f, 80 * density))
            assertEquals(80f, drag(), .5f)
            assertTrue(header.fetchSemanticsNode().boundsInRoot.center.y > first.y + 70 * density)
            moveToRoot(first + Offset(0f, 110 * density))
            assertEquals("A moving local origin changed the physical root-space pull", 110f, drag(), .5f)
            val actualHeight = sheet.fetchSemanticsNode().boundsInRoot.height / density
            assertEquals(1 - 110f / actualHeight, sheet.fetchSemanticsNode().config[SettingsPresenceKey], .001f)
            compose.runOnIdle { assertTrue(browser.settingsActionsCurrent(lease)) }
            assertEquals(originalNode, header.fetchSemanticsNode().id)
            header.performTouchInput { cancel(delayMillis = 0) }; pressed = false
            compose.mainClock.advanceTimeBy(1500)
            assertEquals(0f, drag(), .001f)
            assertEquals(BrowserSurface.SETTINGS, browser.state.value.surface)
            val second = header.fetchSemanticsNode().boundsInRoot.center
            header.performTouchInput { down(center) }; pressed = true
            moveToRoot(second + Offset(0f, 150 * density))
            assertEquals(150f, drag(), .5f)
            header.performTouchInput { up() }; pressed = false
            compose.mainClock.advanceTimeBy(64)
            assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
            assertTrue("Flick used the pre-measure1point height instead of the full sheet", drag() > 150f)
            compose.mainClock.advanceTimeBy(1500)
            sheet.assertDoesNotExist()
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            if (pressed) runCatching {
                compose.runOnIdle { assertTrue(browser.settingsActionsCurrent(lease)) }
                assertEquals(originalNode, header.fetchSemanticsNode().id)
                header.performTouchInput { cancel(delayMillis = 0) }
            }.exceptionOrNull()?.let { cleanup -> failure?.addSuppressed(cleanup) ?: throw cleanup }
        }
    }

    private fun fixture(body: (BrowserController) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val events = mutableListOf<SettingsFunctionalEvent>()
        val lastByStage = mutableMapOf<SettingsFunctionalStage, SettingsFunctionalEvent>()
        var dropped = 0
        val observe: (SettingsFunctionalEvent) -> Unit = { event -> synchronized(events) {
            if (lastByStage[event.stage] != event) {
                lastByStage[event.stage] = event
                if (events.size == 32) { events.removeAt(8); dropped = (dropped + 1).coerceAtMost(10000) }
                events += event
            }
        } }
        fun saveFailure() {
            val case = when (testName.methodName) {
                "entryRetainsTheRootQueryWhileAPagePushIsReversedThroughTheRealHeader" -> "ENTRY"
                "anOutgoingRouteCannotRunItsCapturedToggleOrReviveItAfterReopenAndBackground" -> "OUTGOING_ROUTE"
                "foregroundRebindMakesTheRetainedRealControlTouchableWithoutAnUnrelatedStateChange" -> "FOREGROUND_REBIND"
                "committedEdgeKeepsBackUntilLandingAndHeaderBackDoesNotDismissTheWholeSheet" -> "EDGE_COMMIT"
                "lockedPrivateStillHasFreshUsableGlobalSettingsWithoutItsPageWords" -> "LOCKED_PRIVATE"
                "twoRetainedPreferenceActionsBeforeRecompositionKeepBothPropertyChanges" -> "PROPERTY_MERGE"
                "movingHeaderKeepsRootSpaceDragAndUsesItsMeasuredFullHeightForFlick" -> "MOVING_HEADER"
                else -> "UNKNOWN"
            }
            val receipt = synchronized(events) {
                val rows = JSONArray()
                events.forEach { event -> rows.put(JSONObject().put("stage", event.stage.name).put("reason", event.reason.name)
                    .put("modelPhase", event.modelPhase.name).put("modelDrag", event.modelDrag ?: JSONObject.NULL)
                    .put("composedPhase", event.composedPhase?.name ?: JSONObject.NULL).put("composedDrag", event.composedDrag ?: JSONObject.NULL)
                    .put("leaseBound", event.leaseBound ?: JSONObject.NULL).put("gate", event.gate ?: JSONObject.NULL)
                    .put("claimed", event.claimed ?: JSONObject.NULL).put("targetKeyChanged", event.targetKeyChanged)) }
                JSONObject().put("schema", 1).put("case", case).put("passed", false).put("events", rows)
                    .put("dropped", dropped).put("controlledClock", true).put("nativeCadenceVerified", false)
            }
            val bytes = receipt.toString().toByteArray(Charsets.UTF_8)
            check(bytes.size <= 16384)
            val folder = File(checkNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null)), "instrumentation").also { check(it.isDirectory || it.mkdirs()) }
            File(folder, "settings-functional-$case.json").writeBytes(bytes)
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}
            override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}
            override fun stop(tabId: String) {}
            override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        lateinit var browser: BrowserController
        compose.runOnIdle { browser = BrowserController(object : BrowserRepository {
            override suspend fun load(): BrowserSnapshot? = null
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope) }
        compose.waitUntil(5000) { !browser.state.value.loading }
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) {
            CompositionLocalProvider(LocalSettingsAnimationsEnabled provides true, LocalSettingsFunctionalObserver provides observe) {
                BrowserScreen(browser, modifier = Modifier.testTag("settings.fixture"), pageContent = { _, _, _ -> Text("OWNED-PUBLIC-FIXTURE") })
            }
        } }
        compose.mainClock.autoAdvance = false
        var failure: Throwable? = null
        try { body(browser) }
        catch (error: Throwable) {
            failure = error
            runCatching { saveFailure() }.exceptionOrNull()?.let(error::addSuppressed)
            throw error
        }
        finally {
            try { compose.mainClock.autoAdvance = true; compose.runOnIdle { scope.cancel() } }
            catch (cleanup: Throwable) { failure?.let { it.addSuppressed(cleanup) } ?: throw cleanup }
        }
    }
}

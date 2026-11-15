package dev.yab.browser

import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.AnnotatedString
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Controlled production Settings/route consumer with a RAM public profile. Inert engine, no
 * real webpage/IME or paired-frame acceptance. Native page identity is checked separately. */
class BrowserSettingsSpaceDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private fun activate(node: SemanticsNodeInteraction) = node.performSemanticsAction(SemanticsActions.OnClick) { it() }
    private fun settle() = compose.mainClock.advanceTimeBy(700)

    @Test fun creationAndNameEmojiColorStayInSettingsAndKeepTheOriginalPageMetadata() = fixture { c ->
        val original = c.state.value.spaces.first().tabs.single()
        compose.runOnIdle { c.show(BrowserSurface.SETTINGS) }; settle()
        activate(compose.onNodeWithText("Spaces")); settle()
        activate(compose.onNodeWithTag("settings.spaces.add")); settle()
        val made = c.state.value.selectedSpaceId
        assertNotEquals("personal", made); assertEquals(BrowserSurface.SETTINGS, c.state.value.surface)
        compose.onNodeWithTag("settings.space.name.input").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")))
        compose.onNodeWithTag("settings.space.done").assertIsNotEnabled()
        compose.onNodeWithTag("settings.space.name.input").performTextReplacement("Research")
        activate(compose.onNodeWithTag("settings.space.done")); settle()
        assertEquals("Research", c.state.value.space!!.name)
        compose.onNodeWithTag("settings.space.page").assertExists()
        activate(compose.onNodeWithTag("settings.space.emoji")); settle()
        activate(compose.onNodeWithTag("column.tray.emoji.pick.🎨"))
        activate(compose.onNodeWithTag("settings.space.done")); settle()
        assertEquals("🎨", c.state.value.space!!.emoji)
        val before = c.state.value.space!!.look
        activate(compose.onNodeWithTag("settings.space.color")); settle()
        val preset = compose.onNodeWithTag("space.look.preset.0.1")
        preset.performScrollTo(); activate(preset)
        activate(compose.onNodeWithTag("settings.space.done")); settle()
        assertNotEquals(before, c.state.value.space!!.look)
        assertEquals(made, c.state.value.space!!.id); assertEquals(BrowserSurface.SETTINGS, c.state.value.surface)
        assertEquals(original, c.state.value.spaces.first { it.id == "personal" }.tabs.single())
        compose.onNodeWithTag("settings.space.page").assertExists()
    }

    @Test fun backgroundRevokesTheOldNameActionWhileTheFreshEditorKeepsItsDraft() = fixture { c ->
        compose.runOnIdle { c.show(BrowserSurface.SETTINGS) }; settle()
        activate(compose.onNodeWithText("Spaces")); settle()
        activate(compose.onNodeWithText("Personal")); settle()
        activate(compose.onNodeWithTag("settings.space.name")); settle()
        val name = compose.onNodeWithTag("settings.space.name.input")
        name.performTextReplacement("Retained draft")
        val staleSet = name.fetchSemanticsNode().config[SemanticsActions.SetText].action!!
        val staleDone = originalRenderedClick(compose.onNodeWithTag("settings.space.done").fetchSemanticsNode())
        compose.runOnIdle { c.backgrounded(); c.foregrounded(); staleSet(AnnotatedString("Old input")); staleDone() }
        compose.mainClock.advanceTimeByFrame()
        // The source revokes immediately; the returning editor becomes actionable
        // after its retained presentation finishes the resume transition.
        settle()
        name.assertTextEquals("Retained draft").assertIsEnabled()
        assertEquals("Personal", c.state.value.space!!.name)
        compose.runOnIdle { staleSet(AnnotatedString("Old input after return")); staleDone() }
        name.assertTextEquals("Retained draft")
        name.performTextReplacement("Fresh value")
        activate(compose.onNodeWithTag("settings.space.done").assertIsEnabled()); settle()
        assertEquals("Fresh value", c.state.value.space!!.name)
    }

    @Test fun sameTurnOsBackAfterPushReadsTheLivePathAndDoesNotDismissSettings() = fixture { c ->
        compose.runOnIdle { c.show(BrowserSurface.SETTINGS) }; settle()
        val push = compose.onNodeWithText("Spaces").fetchSemanticsNode().config[SemanticsActions.OnClick].action!!
        compose.runOnIdle {
            push(); compose.activity.onBackPressedDispatcher.onBackPressed()
            assertEquals(BrowserSurface.SETTINGS, c.state.value.surface)
        }
        settle()
        compose.onNodeWithTag("settings.search").assertExists()
        compose.onNodeWithTag("settings.spaces.add").assertDoesNotExist()
        assertEquals(BrowserSurface.SETTINGS, c.state.value.surface)
    }

    private fun fixture(body: (BrowserController) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tab = BrowserTab("page", "https://settings-space.invalid/original", "Owned original", createdAt = 1)
        val original = BrowserSnapshot(spaces = listOf(BrowserSpace("personal", "Personal", tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "personal")
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { error("No navigation during metadata editing") }
            override fun goBack(tabId: String) { error("No native history during metadata editing") }
            override fun goForward(tabId: String) { error("No native history during metadata editing") }
            override fun reload(tabId: String) { error("No reload during metadata editing") }
            override fun stop(tabId: String) {}
            override fun close(tabId: String) { error("No native close during metadata editing") }
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        lateinit var c: BrowserController
        compose.runOnIdle { c = BrowserController(object : BrowserRepository {
            override suspend fun load() = original
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope) }
        compose.waitUntil(5000) { !c.state.value.loading }
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) {
            CompositionLocalProvider(LocalSettingsAnimationsEnabled provides true) {
                BrowserScreen(c, modifier = Modifier.testTag("settings.space.fixture"), pageContent = { _, _, _ -> Text("OWNED-PUBLIC-PAGE") })
            }
        } }
        compose.mainClock.autoAdvance = false
        try { body(c) }
        finally { compose.mainClock.autoAdvance = true; compose.runOnIdle { scope.cancel() } }
    }
}

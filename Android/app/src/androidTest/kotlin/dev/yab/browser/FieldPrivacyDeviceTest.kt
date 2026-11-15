package dev.yab.browser

import android.os.SystemClock
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.BrowserSessionViewModel
import dev.yab.android.MainActivity
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.model.*
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real shipped field controls and native cookie containers; explicit unlock is fixture state only. */
@RunWith(AndroidJUnit4::class)
class FieldPrivacyDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    @Test(timeout = 240_000)
    fun eyesIndicatorAndSubmittedNativeContainerAgreeForPrivateNewTabAndAddress(): Unit = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true") { "Requires the disposable runner device" }
        BrowserInstrumentedTest.FixtureServer().use { server ->
            val scenario = ActivityScenario.launch(MainActivity::class.java)
            lateinit var owner: BrowserSessionViewModel
            var restore: BrowserSnapshot? = null
            var privateId: String? = null
            try {
                scenario.onActivity { owner = ViewModelProvider(it)[BrowserSessionViewModel::class.java] }
                val browser = owner.browser
                val engine = owner.engine
                await("Main profile loaded") { !browser.state.value.loading }
                restore = browser.publicSnapshot()
                main {
                    browser.updateSettings(browser.state.value.settings.copy(welcomed = true, autoClearToday = false, lockPrivate = true))
                    BrowserInstrumentedTest().ownSpace(browser, "Field privacy ${UUID.randomUUID()}")
                    browser.openUrl(server.url("/cookie/write?value=ordinary-eyes"))
                }
                pageText(browser, engine, "Cookie=ordinary-eyes")
                val ordinarySpace = browser.state.value.space!!.id
                val ordinaryProfile = browser.state.value.space!!.websiteProfile
                main { browser.openUrl(server.url("/cookie/write?value=private-eyes"), privately = true); browser.unlockPrivate(true) }
                pageText(browser, engine, "Cookie=private-eyes")
                privateId = browser.state.value.tab!!.id

                main { browser.openField() }
                compose.onNodeWithTag("browser.field.private.page").assertIsDisplayed()
                compose.onNodeWithContentDescription("Turn off private input").performClick()
                // The outgoing Private page is retained for drawing, with no offscreen AT node.
                compose.onNodeWithTag("browser.field.private.page").assertDoesNotExist()
                compose.onNodeWithTag("browser.spaces.capsule").assertIsDisplayed()
                compose.onNodeWithContentDescription("Search privately").assertIsDisplayed()
                assertFalse(browser.state.value.fieldIsPrivate)
                assertEquals(ordinarySpace, browser.state.value.space!!.id)
                compose.onNode(hasSetTextAction()).performTextReplacement(server.url("/cookie/read"))
                compose.onNode(hasSetTextAction()).performImeAction()
                pageText(browser, engine, "Cookie=ordinary-eyes")
                assertFalse(browser.state.value.tab!!.isPrivate)
                assertEquals(ordinaryProfile, browser.state.value.space!!.websiteProfile)

                main { browser.selectTab(privateId!!); browser.unlockPrivate(true); browser.openField(newTab = false) }
                compose.onNodeWithTag("browser.field.private.page").assertIsDisplayed()
                compose.onNodeWithContentDescription("Turn off private input").assertDoesNotExist()
                compose.onNodeWithContentDescription("Search privately").assertDoesNotExist()
                compose.onNodeWithContentDescription("Clear address").performClick()
                compose.onNodeWithContentDescription("Search privately").assertDoesNotExist()
                assertFalse(browser.state.value.fieldPrivate)
                assertTrue(browser.state.value.fieldIsPrivate)
                compose.onNodeWithTag("browser.field.private.page").assertIsDisplayed()
                compose.onNode(hasSetTextAction()).performTextReplacement(server.url("/cookie/read"))
                compose.onNode(hasSetTextAction()).performImeAction()
                pageText(browser, engine, "Cookie=private-eyes")
                assertEquals(privateId, browser.state.value.tab!!.id)
                assertTrue(browser.state.value.space!!.websiteProfile.isPrivate)
                assertTrue(browser.state.value.history.none { it.url.contains("private-eyes") })
                assertFalse(browser.publicSnapshot().toString().contains(privateId!!))
                assertFalse(browser.publicSnapshot().toString().contains("private-eyes"))
            } finally {
                if (restore != null) {
                    main {
                        privateId?.let { owner.browser.closeTab(it) }
                        owner.browser.invalidateUndo()
                        owner.browser.applySyncedSnapshot(restore!!)
                    }
                    await("public fixture restored") { FileBrowserRepository(File(instrumentation.targetContext.filesDir, "browser.json")).load() == restore }
                }
                scenario.close()
            }
        }
    }
    private suspend fun pageText(browser: BrowserController, engine: GeckoEngine, text: String) {
        val until = SystemClock.elapsedRealtime() + 30_000
        while (SystemClock.elapsedRealtime() < until) {
            val body = runCatching { withContext(Dispatchers.Main) { engine.readText(browser.state.value.tab!!).text } }.getOrNull()
            if (body?.contains(text) == true) return
            delay(100)
        }
        error("Owned fixture did not return its expected cookie")
    }
    private suspend fun await(name: String, predicate: suspend () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + 30_000
        while (!predicate()) { check(SystemClock.elapsedRealtime() < until) { "Timed out waiting for $name" }; delay(50) }
    }
    private suspend fun <T> main(block: () -> T): T = withContext(Dispatchers.Main) { block() }
}

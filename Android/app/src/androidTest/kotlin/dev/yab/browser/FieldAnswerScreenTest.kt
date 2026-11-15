package dev.yab.browser

import android.content.ClipboardManager
import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextLayoutResult
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import dev.yab.browser.field.*
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserScreen
import java.time.Instant
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Actual native field, caret, IME action and clipboard. Page engine is an explicit isolated fake. */
class FieldAnswerScreenTest {
    @get:Rule val compose = createAndroidComposeRule<dev.yab.android.EngineTestActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private var chatsOpened = false
    private var askedWords: String? = null
    private val input get() = compose.onNodeWithTag("browser.field.input")
    private val answer get() = compose.onNodeWithTag("browser.field.answer")
    private val clipboard get() = requireNotNull(instrumentation.targetContext.getSystemService(ClipboardManager::class.java))

    @Test fun typedRowsMatchCurrentPhoneCatalog() {
        fixture { browser, _ ->
            compose.runOnIdle { browser.openField(newTab = true) }
            input.performTextReplacement("lisbon weather october")
            compose.waitUntil(10_000) { keyboardVisible() }
            compose.onNodeWithText("Ask Codex", substring = true).assertIsDisplayed()
            val rows = compose.onNodeWithTag("browser.field.rows").assertIsDisplayed()
            val inputRect = input.fetchSemanticsNode().boundsInWindow
            val rowsRect = rows.fetchSemanticsNode().boundsInWindow
            assertTrue("Typed rows stay above the field", rowsRect.bottom <= inputRect.top)
            assertTrue("The field stays inside the app viewport", inputRect.top >= 0)
            val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
            val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
            try { File(folder, "field-search.png").outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
            finally { bitmap.recycle() }
            File(folder, "field-search.json").writeText("""{"kind":"production-component-fixture","screen":"field-search","actualKeyboard":true,"pageEngine":"explicit-fixture-fake","frameParityVerified":false}""")
            input.performTextReplacement("what does anna want?")
            val askRect = compose.onNodeWithText("Ask Codex", substring = true).fetchSemanticsNode().boundsInWindow
            val searchRect = compose.onNode(hasText("what does anna want?", substring = false) and !hasSetTextAction(), useUnmergedTree = true).fetchSemanticsNode().boundsInWindow
            assertTrue("The best question row is nearest the field", askRect.top > searchRect.top)
            val questionBitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
            try { File(folder, "field-question.png").outputStream().use { check(questionBitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
            finally { questionBitmap.recycle() }
            input.performImeAction()
            compose.runOnIdle { assertEquals("what does anna want?", askedWords) }
            compose.onNodeWithContentDescription("Clear address").performClick()
            input.assert(SemanticsMatcher.expectValue(SemanticsProperties.EditableText, androidx.compose.ui.text.AnnotatedString("")))
            compose.runOnIdle { assertEquals("", browser.state.value.fieldText) }
        }
    }

    @Test fun returnAndPlateTapCopyWithoutLeavingTheFieldOrKeyboard() {
        fixture { browser, _ ->
            compose.runOnIdle { browser.openField(newTab = false) }
            input.performTextReplacement("2400")
            compose.onNodeWithTag("browser.field.math.×").performClick()
            input.performTextInput("12"); input.assertTextContains("2400×12")
            answer.assertIsDisplayed()
            record("01-math-keyboard")
            input.performImeAction()
            assertClipboard("28800")
            input.assertIsDisplayed(); answer.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Copied"))
            compose.waitUntil(10_000) { keyboardVisible() }
            input.performTextReplacement("2+2"); answer.performClick(); assertClipboard("4")
            input.assertIsDisplayed(); compose.runOnIdle { assertEquals(BrowserSurface.FIELD, browser.state.value.surface) }
            compose.waitUntil(10_000) { keyboardVisible() }
            record("02-copied-keyboard")
        }
    }

    @Test fun mathKeysRespectSelectionAndSwapAndHoldMenuUseVisibleSides() {
        fixture { browser, _ ->
            compose.runOnIdle { browser.openField() }
            input.performTextReplacement("1234"); input.performTextInputSelection(TextRange(1, 3))
            compose.onNodeWithTag("browser.field.math.×").performClick(); input.assertTextContains("1×4")
            compose.onNodeWithTag("browser.field.math.−").performClick(); input.assertTextContains("1×-4")
            input.performImeAction(); assertClipboard("-4")
            input.performTextReplacement("5 km to mi")
            compose.onNodeWithTag("browser.field.answer.swap").performClick()
            answer.assertContentDescriptionEquals("3.1069 mi is 5 km")
            // The plate centre is the independent Swap control, as on iPhone.
            answer.performTouchInput { click(Offset(width * 0.8f, height / 2f)) }
            assertClipboard("5 km")
            answer.assertContentDescriptionEquals("3.1069 mi is 5 km")
                .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Copied"))
            record("03-reversed-units")
            input.performTextReplacement("2400*12")
            answer.performTouchInput { longClick() }
            compose.onNodeWithText("Copy Answer").assertExists()
            record("04-answer-hold-menu")
            compose.onNodeWithText("Copy Question").performClick(); assertClipboard("2400 × 12")
            input.assertIsDisplayed(); compose.waitUntil(10_000) { keyboardVisible() }
        }
    }

    @Test fun privatePendingRatesTimeAndChatsKeepTheirOwnReturnBehavior() {
        fixture { browser, rates ->
            compose.runOnIdle { browser.openField(privately = true) }
            input.performTextReplacement("20% of 80"); input.performImeAction(); assertClipboard("16")
            compose.runOnIdle { assertTrue(browser.state.value.fieldIsPrivate); assertEquals(BrowserSurface.FIELD, browser.state.value.surface) }
            assertPrivateWordsReadable()
            record("05-private-answer")
            compose.runOnIdle { browser.openField(); rates.value = FieldRatesSnapshot() }
            input.performTextReplacement("100 dollars to euros")
            answer.assertIsNotEnabled(); answer.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Getting rates"))
            compose.runOnIdle { rates.value = rates.value.copy(failed = true) }
            answer.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Rates unavailable"))
            record("06-unavailable-rates")
            input.performTextReplacement("time in tokyo"); input.performImeAction()
            compose.runOnIdle { assertEquals(BrowserSurface.PAGE, browser.state.value.surface) }
            assertClipboard("16")
            compose.runOnIdle { browser.openField() }
            input.performTextReplacement("2+2")
            // Current Phone keeps the capsule visible but blocks its actions
            // while query rows are shown. Return to the actual empty-card route.
            compose.onNodeWithContentDescription("Clear address").performClick()
            compose.onNodeWithContentDescription("Chats").performClick()
            compose.runOnIdle {
                assertFalse(chatsOpened)
                assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
                assertTrue(browser.state.value.fieldResting)
                assertEquals("", browser.state.value.fieldText)
            }
            compose.onNodeWithText("Open Chats").assertIsDisplayed().assertIsEnabled().performClick()
            compose.runOnIdle { assertTrue(chatsOpened); assertEquals(BrowserSurface.PAGE, browser.state.value.surface) }
            answer.assertDoesNotExist()
            compose.onNodeWithTag("browser.field.math.+").assertDoesNotExist()
        }
    }

    @Test fun completedOriginalPasteCannotCloseWordsEditedWhileThePageAnswers() {
        val reply = CompletableDeferred<Boolean>()
        val inserted = mutableListOf<String>()
        val target = object : FieldAnswerTarget {
            private var spent = false
            override val ready get() = !spent
            override suspend fun insert(value: String): Boolean {
                if (!ready) return false
                spent = true; inserted += value
                return reply.await()
            }
            override fun revoke() { spent = true }
        }
        fixture(target) { browser, _ ->
            compose.runOnIdle { browser.openField(newTab = false) }
            input.performTextReplacement("2400*12")
            answer.performTouchInput { longClick() }
            compose.onNodeWithText("Paste into Page").assertIsEnabled().performClick()
            compose.waitUntil(10_000) { inserted.isNotEmpty() }
            input.performTextReplacement("2+2")
            compose.runOnIdle { reply.complete(true) }
            compose.waitForIdle()
            input.assertIsDisplayed().assertTextContains("2+2")
            compose.runOnIdle { assertEquals(BrowserSurface.FIELD, browser.state.value.surface); assertEquals(listOf("28800"), inserted) }
            record("07-late-paste-keeps-new-words")
        }
    }

    @Test fun hexColorAnswerCopiesNormalizedHexThroughReturnAndPlateWithoutLeavingTheField() {
        fun assertFullSide(words: String) {
            val actual = mutableListOf<TextLayoutResult>()
            compose.onNodeWithText(words, useUnmergedTree = true)
                .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { action -> assertTrue(action(actual)) }
            val layout = actual.single()
            assertEquals(words, layout.layoutInput.text.text)
            assertEquals(1, layout.lineCount)
            val side = when (words) {
                "#AABBCC" -> "ABC_HEX"
                "RGB 170, 187, 204" -> "ABC_RGB"
                "#00AAFF" -> "OAF_HEX"
                "RGB 0, 170, 255" -> "OAF_RGB"
                else -> "UNEXPECTED_FIXTURE_SIDE"
            }
            val paragraph = layout.multiParagraph
            val constraints = layout.layoutInput.constraints
            val diagnostic = buildString {
                append("case=$side size=${layout.size.width}x${layout.size.height}")
                append(" paragraph=${paragraph.width}x${paragraph.height} exceededMaxLines=${paragraph.didExceedMaxLines}")
                append(" constraints=${constraints.minWidth},${constraints.maxWidth},${constraints.minHeight},${constraints.maxHeight}")
                append(" overflowWidth=${layout.didOverflowWidth} overflowHeight=${layout.didOverflowHeight}")
                append(" line0Ellipsized=${layout.isLineEllipsized(0)} visibleEnd=${layout.getLineEnd(0, visibleEnd = true)}")
                append(" fontSize=${layout.layoutInput.style.fontSize} lineHeight=${layout.layoutInput.style.lineHeight}")
            }.take(2048)
            assertFalse(("The actual answer side overflowed: $words; $diagnostic").take(2048), layout.hasVisualOverflow)
            assertFalse("The actual answer side was ellipsized: $words", layout.isLineEllipsized(0))
            assertEquals(words.length, layout.getLineEnd(0, visibleEnd = true))
        }
        fixture { browser, _ ->
            compose.runOnIdle { browser.openField(newTab = false) }
            input.performTextReplacement("#abc")
            input.assertIsDisplayed().assertIsFocused().assertTextContains("#abc")
            answer.assertIsDisplayed().assertIsEnabled().assertContentDescriptionEquals("#AABBCC is RGB 170, 187, 204")
            compose.onNodeWithText("#AABBCC", useUnmergedTree = true).assertIsDisplayed()
            compose.onNodeWithText("RGB 170, 187, 204", useUnmergedTree = true).assertIsDisplayed()
            compose.onNodeWithText("HEX", useUnmergedTree = true).assertIsDisplayed()
            compose.onNodeWithText("RGB", useUnmergedTree = true).assertIsDisplayed()
            compose.onNodeWithTag("browser.field.answer.swap").assertDoesNotExist()
            for (symbol in listOf("+", "−", "×", "÷", "(", ")", "%"))
                compose.onNodeWithTag("browser.field.math.$symbol").assertDoesNotExist()
            input.performImeAction()
            assertClipboard("#AABBCC")
            input.assertIsDisplayed().assertIsFocused().assertTextContains("#abc")
            answer.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Copied"))
            compose.runOnIdle { assertEquals(BrowserSurface.FIELD, browser.state.value.surface); assertEquals("#abc", browser.state.value.fieldText) }
            compose.waitUntil(10_000) { keyboardVisible() }
            assertFullSide("#AABBCC"); assertFullSide("RGB 170, 187, 204")
            record("08-hex-return-keyboard")

            input.performTextReplacement("#0af")
            answer.assertIsDisplayed().assertContentDescriptionEquals("#00AAFF is RGB 0, 170, 255")
            compose.onNodeWithText("#00AAFF", useUnmergedTree = true).assertIsDisplayed()
            compose.onNodeWithText("RGB 0, 170, 255", useUnmergedTree = true).assertIsDisplayed()
            compose.onNodeWithTag("browser.field.answer.swap").assertDoesNotExist()
            for (symbol in listOf("+", "−", "×", "÷", "(", ")", "%"))
                compose.onNodeWithTag("browser.field.math.$symbol").assertDoesNotExist()
            answer.performClick()
            assertClipboard("#00AAFF")
            input.assertIsDisplayed().assertIsFocused().assertTextContains("#0af")
            compose.runOnIdle { assertEquals(BrowserSurface.FIELD, browser.state.value.surface); assertEquals("#0af", browser.state.value.fieldText) }
            compose.waitUntil(10_000) { keyboardVisible() }
            assertFullSide("#00AAFF"); assertFullSide("RGB 0, 170, 255")

            input.performTextReplacement("#abcd")
            answer.assertDoesNotExist()
            compose.onNodeWithTag("browser.field.answer.swap").assertDoesNotExist()
            input.assertIsDisplayed().assertIsFocused().assertTextContains("#abcd")
            compose.runOnIdle { assertEquals(BrowserSurface.FIELD, browser.state.value.surface) }
            assertClipboard("#00AAFF")
        }
    }

    private fun assertClipboard(value: String) {
        compose.runOnIdle { assertEquals(value, clipboard.primaryClip?.getItemAt(0)?.text?.toString()) }
    }
    private fun assertPrivateWordsReadable() {
        val pixels = input.captureToImage().toPixelMap()
        // Restrict to the word area, excluding the cursor at the trailing end.
        // This catches light-theme black glyphs on the private dark field.
        val left = (pixels.width * 0.08f).toInt()
        val right = (pixels.width * 0.65f).toInt()
        val top = (pixels.height * 0.25f).toInt()
        val bottom = (pixels.height * 0.75f).toInt()
        var light = 0
        for (y in top until bottom) for (x in left until right) {
            val pixel = pixels[x, y]
            if (pixel.red > 0.7f && pixel.green > 0.7f && pixel.blue > 0.7f) light++
        }
        assertTrue("Private field words have no readable light ink on their dark surface",
            light > (right - left) * (bottom - top) * 0.005f)
    }
    private fun record(name: String) {
        compose.waitForIdle()
        if (keyboardVisible()) assertAnswerAboveKeyboard()
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "instrumentation/field-answer-screen").apply { mkdirs() }
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot()) { "Owned field UI screenshot unavailable" }
        try { File(folder, "$name.png").outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        val roots = compose.onAllNodes(isRoot(), useUnmergedTree = true)
        File(folder, "$name-semantics.txt").writeText((0 until roots.fetchSemanticsNodes().size).joinToString("\n") { roots[it].printToString() })
        File(folder, "evidence.json").writeText("""{"kind":"native-field-stills","actualKeyboard":true,"windowSoftInputMode":"adjustResize","edgeToEdge":true,"pageEngine":"explicit-fixture-fake","frameParityVerified":false,"physicalDeviceSmoothnessVerified":false}""")
    }
    private fun assertAnswerAboveKeyboard() {
        var keyboardTop = 0
        var safeTop = 0
        compose.runOnIdle {
            val decor = compose.activity.window.decorView
            val insets = requireNotNull(ViewCompat.getRootWindowInsets(decor))
            keyboardTop = decor.height - insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            safeTop = insets.getInsets(WindowInsetsCompat.Type.statusBars()).top
        }
        val inputRect = input.fetchSemanticsNode().boundsInWindow
        val answerRect = answer.fetchSemanticsNode().boundsInWindow
        assertTrue("The answer was panned above the safe app viewport", answerRect.top >= safeTop)
        assertTrue("The answer overlaps the field", answerRect.bottom <= inputRect.top)
        assertTrue("The browser field overlaps the native keyboard", inputRect.bottom <= keyboardTop + 1)
    }
    private fun keyboardVisible(): Boolean {
        var visible = false
        instrumentation.runOnMainSync {
            visible = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).any {
                ViewCompat.getRootWindowInsets(it.window.decorView)?.isVisible(WindowInsetsCompat.Type.ime()) == true
            }
        }
        return visible
    }
    private fun fixture(target: FieldAnswerTarget? = null, block: (BrowserController, MutableStateFlow<FieldRatesSnapshot>) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val previousClipboard = clipboard.primaryClip
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tab = BrowserTab("field-answer-page", "https://owned.test/fixture", createdAt = 1)
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("field-answer-space", "Field answers", tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "field-answer-space")
        val repository = object : BrowserRepository {
            override suspend fun load() = snapshot
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }
        val engine = object : BrowserEngine {
            override suspend fun captureFieldAnswerTarget(tabId: String) = target
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}
            override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}
            override fun stop(tabId: String) {}
            override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val browser = BrowserController(repository, engine, scope)
        val rates = MutableStateFlow(FieldRatesSnapshot(mapOf("EUR" to 0.9), Instant.now()))
        val rateSource = object : FieldRateSource { override val state = rates; override fun warm() {} }
        try {
            compose.setContent {
                CompositionLocalProvider(LocalFieldRateSource provides rateSource) {
                    BrowserScreen(browser, onOpenChats = { chatsOpened = true }, fieldAgentName = "Codex", onAskQuestion = { words, _ -> askedWords = words }) { _, _, modifier -> Box(modifier.fillMaxSize().background(Color.White)) }
                }
            }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            block(browser, rates)
        } finally {
            scope.cancel()
            compose.runOnIdle { if (previousClipboard == null) clipboard.clearPrimaryClip() else clipboard.setPrimaryClip(previousClipboard) }
        }
    }
}

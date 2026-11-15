package dev.yab.agent

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.AnnotatedString
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic component drafts only. No payment, provider, biometric or PIN is used. */
@RunWith(AndroidJUnit4::class)
class ApprovalPaymentLifetimeDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private class Port : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("fixture-account", listOf(RemoteMac("fixture-mac", "Fixture Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        var answers = 0
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) { answers++ }
    }
    private fun payment() = ApprovalPayment("fixture.test", "Synthetic item", "$42",
        cards = listOf(ApprovalCard("a", "Visa", "1111", "First"), ApprovalCard("b", "Mastercard", "2222", "Second")),
        places = listOf(ApprovalPlace("home", "1 Fixture Lane", "Fixture Home"), ApprovalPlace("office", "2 Fixture Lane", "Fixture Office")),
        card = "a", place = "home", takesCard = true, takesPlace = true)
    private fun clickAction(label: String): () -> Boolean = dev.yab.browser.originalRenderedClick(
        compose.onNodeWithText(label).performScrollTo().fetchSemanticsNode())
    private fun editAction(label: String): (AnnotatedString) -> Boolean = checkNotNull(compose.onNodeWithText(label).performScrollTo()
        .fetchSemanticsNode().config[SemanticsActions.SetText].action)
    private fun fieldsPresent() = compose.onAllNodesWithText("Card number").fetchSemanticsNodes().size == 1 &&
        compose.onAllNodesWithText("Street").fetchSemanticsNodes().size == 1
    private fun text(label: String): String = compose.onNodeWithText(label).performScrollTo().fetchSemanticsNode()
        .config[SemanticsProperties.EditableText].text
    private fun enterDrafts() {
        compose.onNodeWithText("Use a new card").performScrollTo().performClick()
        compose.onNodeWithText("Use a new address").performScrollTo().performClick()
        compose.onNodeWithText("Card number").performScrollTo().performTextReplacement("11112222")
        compose.onNodeWithText("Security code").performScrollTo().performTextReplacement("123")
        compose.onNodeWithText("Street").performScrollTo().performTextReplacement("Synthetic Street")
        compose.onNodeWithText("City").performScrollTo().performTextReplacement("Synthetic City")
    }
    private fun assertOriginalDrafts() {
        assertEquals("11112222", text("Card number"))
        assertEquals(3, text("Security code").length)
        assertEquals("Synthetic Street", text("Street"))
        assertEquals("Synthetic City", text("City"))
    }

    @Test(timeout = 90_000)
    fun actualStoppedPromptPaymentActionsCannotRetargetItsResumedOwner() {
        val port = Port(); val now = System.currentTimeMillis(); val controller = ApprovalController(port) { now }
        val request = ApprovalRequest("payment-owner-fixture", "fixture-account", "fixture-mac", 1, now + 300_000,
            "Claude", "Synthetic payment", "Owned component fixture", ApprovalKind.PAYMENT, payment = payment(),
            requestDigest = "fixture-payment-digest", verb = "Pay $42")
        controller.replaceValidated(listOf(request))
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller, null) } }
        enterDrafts()
        val oldCard = clickAction("Visa ···· 1111 · First")
        val oldPlace = clickAction("Fixture Home · 1 Fixture Lane")
        val oldNewCard = clickAction("Cancel new card")
        val oldNewPlace = clickAction("Cancel new address")
        val oldCardEdit = editAction("Card number"); val oldStreetEdit = editAction("Street")
        val originalSource = compose.runOnIdle { checkNotNull(controller.captureDisplayed(request)) }
        val originalActivity = compose.activity
        val stopped = AtomicBoolean(false)
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) stopped.set(true) }
        compose.runOnIdle { originalActivity.lifecycle.addObserver(observer) }
        try {
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            compose.waitForIdle()
            assertTrue("The original component host must actually reach STOP", stopped.get())
            assertSame(originalActivity, compose.activity)
            compose.onNodeWithText("Card number").performScrollTo().assertIsEnabled()
            assertOriginalDrafts()
            compose.runOnIdle { assertTrue(controller.isDisplayedCurrent(originalSource)); assertEquals(listOf(request), controller.state.value.requests) }
            compose.runOnIdle { oldCard() }
            assertTrue("Retired payment card selection changed the original editor", fieldsPresent())
            for (old in listOf(oldPlace, oldNewCard, oldNewPlace)) {
                compose.runOnIdle { old() }
                assertTrue("Retired payment buttons must leave both original drafts open", fieldsPresent())
                assertOriginalDrafts()
            }
            compose.runOnIdle { oldCardEdit(AnnotatedString("99990000")); oldStreetEdit(AnnotatedString("Retired synthetic street")) }
            assertOriginalDrafts()
            compose.onNodeWithText("Card number").performScrollTo().performTextReplacement("33334444")
            assertEquals("33334444", text("Card number")); assertEquals("Synthetic Street", text("Street"))
            compose.onNodeWithText("Mastercard ···· 2222 · Second").performScrollTo().performClick().assertIsSelected()
            assertEquals("Synthetic Street", text("Street"))
            compose.onNodeWithText("Fixture Office · 2 Fixture Lane").performScrollTo().performClick().assertIsSelected()
            compose.runOnIdle {
                assertEquals(listOf(request), controller.state.value.requests)
                assertNull(controller.state.value.busy); assertNull(controller.state.value.error)
                assertTrue(controller.state.value.deferred.isEmpty()); assertEquals(0, port.answers)
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.lifecycle.removeObserver(observer) }
        }
    }

    @Test(timeout = 90_000)
    fun renderedDisabledPaymentActionsCannotRetargetItsReenabledEditor() {
        val payment = payment(); val enabled = mutableStateOf(true)
        val picks = mutableStateOf(ApprovalPicks(card = "a", place = "home")); var changes = 0
        compose.setContent {
            BrowserTheme(BrowserAppearance.LIGHT) {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                    ApprovalPaymentEditor(payment, picks.value, enabled = enabled.value) { value -> changes++; picks.value = value }
                }
            }
        }
        enterDrafts()
        val oldCard = clickAction("Visa ···· 1111 · First")
        val oldPlace = clickAction("Fixture Home · 1 Fixture Lane")
        val oldNewCard = clickAction("Cancel new card"); val oldNewPlace = clickAction("Cancel new address")
        val oldCardEdit = editAction("Card number"); val oldStreetEdit = editAction("Street")
        compose.runOnIdle { enabled.value = false }
        compose.onNodeWithText("Card number").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("Cancel new address").performScrollTo().assertIsNotEnabled()
        compose.runOnIdle { enabled.value = true }
        compose.onNodeWithText("Card number").performScrollTo().assertIsEnabled()
        assertOriginalDrafts()
        val changesBeforeRetiredActions = compose.runOnIdle { changes }
        compose.runOnIdle { oldCard() }
        assertTrue("Disabled payment card selection revived after reenable", fieldsPresent())
        for (old in listOf(oldPlace, oldNewCard, oldNewPlace)) {
            compose.runOnIdle { old() }
            assertTrue("Disabled payment buttons must not adopt the enabled replacement", fieldsPresent())
            assertOriginalDrafts()
        }
        compose.runOnIdle { oldCardEdit(AnnotatedString("99990000")); oldStreetEdit(AnnotatedString("Retired synthetic street")) }
        assertOriginalDrafts()
        compose.runOnIdle { assertEquals(changesBeforeRetiredActions, changes) }
        val sameOwnerField = compose.onNodeWithText("Card number").performScrollTo().fetchSemanticsNode().id
        compose.onNodeWithText("Street").performScrollTo().performTextReplacement("Fresh Synthetic Street")
        assertEquals(sameOwnerField, compose.onNodeWithText("Card number").performScrollTo().fetchSemanticsNode().id)
        compose.onNodeWithText("Card number").performScrollTo().performTextReplacement("55556666")
        compose.runOnIdle {
            assertEquals("55556666", picks.value.newCard?.number)
            assertEquals("Fresh Synthetic Street", picks.value.newPlace?.street)
        }
        val disposedCardEdit = editAction("Card number")
        val disposedPlaceEdit = editAction("Street")
        val disposedCancelCard = clickAction("Cancel new card")
        val disposedCancelPlace = clickAction("Cancel new address")
        compose.onNodeWithText("Mastercard ···· 2222 · Second").performScrollTo().performClick().assertIsSelected()
        compose.runOnIdle { disposedCardEdit(AnnotatedString("Retired hidden card")); disposedCancelCard() }
        compose.runOnIdle {
            assertEquals("b", picks.value.card); assertNull(picks.value.newCard)
            assertEquals("Fresh Synthetic Street", picks.value.newPlace?.street)
        }
        compose.onNodeWithText("Fixture Office · 2 Fixture Lane").performScrollTo().performClick().assertIsSelected()
        compose.runOnIdle { disposedPlaceEdit(AnnotatedString("Retired hidden street")); disposedCancelPlace() }
        compose.runOnIdle { assertEquals("office", picks.value.place); assertNull(picks.value.newPlace) }
        compose.onNodeWithText("Use a new card").performScrollTo().performClick()
        assertEquals("55556666", text("Card number"))
        compose.onNodeWithText("Card number").performScrollTo().performTextReplacement("77778888")
        compose.runOnIdle { assertEquals("77778888", picks.value.newCard?.number); assertEquals("office", picks.value.place) }
        compose.onNodeWithText("Use a new address").performScrollTo().performClick()
        assertEquals("Fresh Synthetic Street", text("Street"))
        compose.onNodeWithText("Street").performScrollTo().performTextReplacement("Reopened Synthetic Street")
        compose.runOnIdle {
            assertEquals("77778888", picks.value.newCard?.number)
            assertEquals("Reopened Synthetic Street", picks.value.newPlace?.street)
        }
    }
}

package dev.yab.agent

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic decrypted requests and actual production UI/actions. No provider or biometric acceptance. */
@RunWith(AndroidJUnit4::class)
class ApprovalCurrentWorkflowDeviceTest {
    @get:Rule val compose = createComposeRule()
    private class Port : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        val answers = mutableListOf<ApprovalAnswer>()
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) { answers += answer }
    }
    private val now = System.currentTimeMillis()
    private fun request(id: String = "fixture") = ApprovalRequest(id, "account", "mac", 1, now + 300_000,
        "Claude", "Synthetic approval", "Owned fixture", requestDigest = "$id-digest", detailDigest = "$id-detail",
        place = "chat:owned-fixture", sourceEpoch = 0, sourceSession = "owned-native-session", sourceIssuedAt = 1.0)
    private fun show(controller: ApprovalController, proof: ApprovalAuthentication? = null) {
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller, proof) } }
    }

    @Test fun readAndLegacyMailConsentShowWholeChatLifetimeBeforeAnyAnswer() {
        val port = Port(); val controller = ApprovalController(port) { now }
        val first = request().copy(kind = ApprovalKind.MAIL_SEARCH, permit = "mail.read", lines = listOf("Planning", "once for this chat"),
            text = "Opens “Train tickets”\nOnly the linked account.")
        controller.replaceValidated(listOf(first)); show(controller)
        compose.onNodeWithText("Let Claude read your mail?").assertExists()
        compose.onNodeWithText("Train tickets").assertExists()
        compose.onNodeWithTag("approval.search.scope").assertTextEquals("And any mail after it, until this chat ends.")
        compose.onNodeWithText("Only the linked account.").assertExists()
        compose.runOnIdle { controller.replaceValidated(listOf(first.copy(text = null, revision = 2))) }
        compose.onNodeWithTag("approval.search.scope").assertTextEquals("Every search in this chat, until it ends.")
        compose.runOnIdle { assertTrue(port.answers.isEmpty()) }
    }

    @Test fun olderMacBatchCanOpenExactSecondMailWithoutRewritingTheRequest() {
        val port = Port(); val controller = ApprovalController(port) { now }
        val original = request().copy(kind = ApprovalKind.LINES, permit = "mail.send", lines = listOf(
            "1. To first@example.test · First subject\nFirst body\n2. To second@example.test · Bcc blind@example.test · Second subject\nSecond body"))
        val facts = original.fingerprint()
        controller.replaceValidated(listOf(original)); show(controller)
        compose.onNodeWithText("Send All 2").assertExists()
        compose.onNodeWithContentDescription("Read full email: Second subject").performScrollTo().performClick()
        compose.onNodeWithTag("approval.window.bcc").assertTextEquals("bcc blind@example.test")
        compose.onNodeWithText("Second body").assertExists()
        compose.runOnIdle {
            assertEquals(1, controller.windowPages.frame.value.selected)
            assertEquals(facts, controller.state.value.requests.single().fingerprint())
            assertTrue(controller.state.value.requests.single().mails.isEmpty())
            assertTrue(port.answers.isEmpty())
        }
    }

    @Test fun oneExactAccountRowRunsAuthenticationAndSendsItsChoiceOnce() {
        val port = Port(); val controller = ApprovalController(port) { now }
        var proofs = 0
        val gate = object : ApprovalAuthentication { override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
            proofs++; return DeviceAuthenticationProof(now)
        } }
        val original = request().copy(kind = ApprovalKind.ACCOUNTS, choices = listOf("first@example.test", "second@example.test"), verb = "Sign In")
        controller.replaceValidated(listOf(original)); show(controller, gate)
        compose.onNodeWithText("Tap an account to sign in").assertExists()
        compose.onNodeWithText("Sign In").assertDoesNotExist()
        compose.onNodeWithContentDescription("Sign in as second@example.test").performScrollTo().performClick()
        compose.runOnIdle {
            assertEquals(1, proofs)
            assertEquals(1, port.answers.size)
            assertEquals("second@example.test", port.answers.single().choice)
            assertEquals(original, port.answers.single().request)
        }
    }

    @Test fun declinedPaymentReaskKeepsValidCardButRequiresFreshAmountAndAuthentication() {
        val port = Port(); val controller = ApprovalController(port) { now }
        var proofs = 0
        val gate = object : ApprovalAuthentication { override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
            proofs++; return DeviceAuthenticationProof(now)
        } }
        val pay = ApprovalPayment("store.test", "Book", "$42", cards = listOf(
            ApprovalCard("a", "Visa", "1111", "First"), ApprovalCard("b", "Mastercard", "2222", "Second")), card = "a", takesCard = true)
        val original = request("first").copy(kind = ApprovalKind.PAYMENT, payment = pay, verb = "Pay $42")
        val retry = request("retry").copy(kind = ApprovalKind.PAYMENT, payment = pay.copy(amount = "$43"), verb = "Pay $43", sourceIssuedAt = 2.0)
        controller.replaceValidated(listOf(original)); show(controller, gate)
        compose.onNodeWithText("Mastercard ···· 2222 · Second").performScrollTo().performClick()
        compose.onNodeWithText("Pay $42").performClick()
        compose.runOnIdle {
            assertEquals(1, port.answers.size)
            controller.replaceResults(listOf(ApprovalResult(original.id, original.account, original.mac, "first-digest",
                ApprovalResultPhase.declined, "Site refused", null, now / 1000.0)))
            controller.replaceValidated(listOf(retry))
        }
        compose.onNodeWithText("Try Again · $43").assertExists()
        compose.onNodeWithText("Mastercard ···· 2222 · Second · Declined by store.test").performScrollTo().assertIsSelected()
        compose.onNodeWithText("Try Again · $43").performClick()
        compose.runOnIdle {
            assertEquals(2, proofs)
            assertEquals(2, port.answers.size)
            assertEquals(retry, port.answers.last().request)
            assertEquals("b", port.answers.last().picks.card)
        }
    }

    @Test fun pendingAuthenticationDisablesEveryPaymentEditorControlAndSendsTheCapturedFactsOnce() {
        val port = Port(); val controller = ApprovalController(port) { now }
        val entered = java.util.concurrent.atomic.AtomicBoolean(false)
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val staleEdits = mutableListOf<(androidx.compose.ui.text.AnnotatedString) -> Boolean>()
        var proofs = 0
        val gate = object : ApprovalAuthentication { override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
            proofs++; entered.set(true)
            check(android.os.Looper.myLooper() === android.os.Looper.getMainLooper())
            assertNotNull(controller.state.value.busy)
            // These actions came from the last enabled composition. Invoke them
            // on the same Main stack as authentication, before recomposition.
            for (edit in staleEdits) assertTrue(edit(androidx.compose.ui.text.AnnotatedString("Retired queued edit")))
            release.await(); return DeviceAuthenticationProof(now)
        } }
        val pay = ApprovalPayment("store.test", "Book", "$42", cards = listOf(ApprovalCard("a", "Visa", "1111", "First")),
            places = listOf(ApprovalPlace("home", "Fixture Street", "Fixture Person")), card = "a", place = "home", takesCard = true, takesPlace = true)
        val original = request().copy(kind = ApprovalKind.PAYMENT, payment = pay, verb = "Pay $42")
        controller.replaceValidated(listOf(original)); show(controller, gate)
        compose.onNodeWithText("Use a new card").performScrollTo().performClick()
        val year = java.time.YearMonth.now().year + 1
        val values = linkedMapOf("Card number" to "4111111111111111", "MM/YY" to "12/$year", "Security code" to "123", "Name on card" to "Fixture Person")
        for ((label, value) in values) compose.onNodeWithText(label).performScrollTo().performTextInput(value)
        compose.onNodeWithText("Use a new address").performScrollTo().performClick()
        values += linkedMapOf("Name" to "Fixture Person", "Street" to "Synthetic Street", "City" to "Fixture City", "Postal code" to "12345")
        for ((label, value) in values.entries.drop(4)) compose.onNodeWithText(label).performScrollTo().performTextInput(value)
        for (label in listOf("Card number", "Street")) staleEdits += checkNotNull(compose.onNodeWithText(label).fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsActions.SetText].action)
        compose.onNodeWithText("Pay $42").performClick()
        compose.waitUntil(5000) { entered.get() }
        for ((label, value) in values) {
            val node = compose.onNodeWithText(label).assertIsNotEnabled().fetchSemanticsNode()
            val text = node.config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text
            if (label == "Security code") assertEquals(value.length, text.length) else assertEquals(value, text)
        }
        for (label in listOf("Visa ···· 1111 · First", "Fixture Person · Fixture Street", "Cancel new card", "Cancel new address"))
            compose.onNodeWithText(label).assertIsNotEnabled()
        compose.runOnIdle { assertEquals(original.id, controller.state.value.busy); assertEquals(1, proofs); assertTrue(port.answers.isEmpty()) }
        compose.runOnIdle { release.complete(Unit) }
        compose.runOnIdle {
            assertEquals(1, proofs); assertEquals(original, port.answers.single().request)
            assertEquals(ApprovalPicks(newCard = ApprovalNewCard("4111111111111111", "123", "Fixture Person", 12, year),
                newPlace = ApprovalNewPlace("Fixture Person", "Synthetic Street", "Fixture City", "12345")), port.answers.single().picks)
        }
    }
}

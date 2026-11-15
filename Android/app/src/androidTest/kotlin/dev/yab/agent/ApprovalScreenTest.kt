package dev.yab.agent

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import dev.yab.core.sync.Clock
import dev.yab.core.sync.Record
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Consumer-only controlled result fixtures. No payment provider is contacted by this test. */
@RunWith(AndroidJUnit4::class)
class ApprovalScreenTest {
    @get:Rule val compose = createComposeRule()
    private class DraftPort : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("account-a", listOf(RemoteMac("mac", "Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        var answers = 0
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer): Unit { answers++;error("Draft fixture must never answer") }
    }
    @Test fun nativeApprovalWaitsForAnOwnedResultAndFooterOnlyOffersTheSourceAction() {
        val port = object : AgentSyncPort {
            override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, emptySet()))))
            override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
            override val approvalResults = MutableStateFlow(emptyList<ApprovalResult>())
            val answers = mutableListOf<ApprovalAnswer>()
            override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
            override suspend fun stop(owner: RemoteOwner) {}
            override suspend fun delete(owner: RemoteOwner) {}
            override suspend fun answerApproval(answer: ApprovalAnswer) { answers += answer }
        }
        val now = System.currentTimeMillis()
        val controller = ApprovalController(port) { now }
        val request = ApprovalRequest("00000000-0000-0000-0000-000000000060", "account", "mac", 1, System.currentTimeMillis() + 60_000,
            "Claude", "Pay for this book?", "store.test", ApprovalKind.PAYMENT, payment = ApprovalPayment("store.test", "Book", "$42"), verb = "Pay $42", requestDigest = "retained-facts")
        val proof = object : ApprovalAuthentication { override suspend fun authenticate(reason: String) = DeviceAuthenticationProof(now) }
        controller.replaceValidated(listOf(request))
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller, proof) } }
        androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        compose.onNodeWithText("Pay for this book?").assertExists()
        compose.runOnIdle { assertTrue(controller.state.value.deferred.isEmpty()); assertTrue(port.answers.isEmpty()) }
        compose.onNodeWithText("Later").assertDoesNotExist()
        compose.onNodeWithText("Decline").assertDoesNotExist()
        compose.onNodeWithContentDescription("Decline approval").assertExists()
        compose.onNodeWithText("Pay $42").performClick()
        compose.onNodeWithText("Sent to your Mac").assertExists()
        compose.onNodeWithTag("approval.sending", useUnmergedTree = true).assertExists()
        compose.onNodeWithText("Paid").assertDoesNotExist()
        compose.runOnIdle { assertEquals(1, port.answers.size) }
        fun observed(phase: String): ApprovalResult {
            val body = buildJsonObject { put("id", request.id); put("phase", phase); put("order", "FixtureOrder42"); put("at", 1234) }
            val record = Record("assistantresult", request.id).updated(buildJsonObject { put("body", body.toString()) }, Clock("mac"))
            return checkNotNull(ApprovalResultCodec.read(record, request))
        }
        compose.runOnIdle { port.approvalResults.value = listOf(observed("paying")) }
        compose.onNodeWithTag("approval.paying", useUnmergedTree = true).assertTextEquals("Paying on store.test")
        compose.onNodeWithTag("approval.footLine").assertTextEquals("This can take a few seconds")
        compose.runOnIdle { port.approvalResults.value = listOf(observed("paid")) }
        compose.onNodeWithTag("approval.completed", useUnmergedTree = true).assertTextEquals("Paid")
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Order FixtureOrder42")
        compose.runOnIdle { port.connection.value = RemoteConnection("another-account"); controller.replaceResults(port.approvalResults.value) }
        compose.onNodeWithText("Paid").assertDoesNotExist()
    }
    @Test fun failedFooterIsCloseOnlyAndOldReadyOrErrorCallbacksCannotBorrowTheNewEpoch() {
        val port=DraftPort();val now=System.currentTimeMillis();val controller=ApprovalController(port){now}
        val request=ApprovalRequest("failure","account-a","mac",1,now+300_000,"Claude","Owned failure","Exact fixture",verb="Approve")
        var proofs=0
        val gate=object:ApprovalAuthentication { override suspend fun authenticate(reason:String):DeviceAuthenticationProof {
            proofs++;error("Same owned error")
        } }
        controller.replaceValidated(listOf(request))
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller,gate) } }
        val oldReady=dev.yab.browser.originalRenderedClick(compose.onNodeWithTag("approval.yes").fetchSemanticsNode())
        compose.onNodeWithTag("approval.yes").performClick()
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Same owned error")
        compose.onNodeWithTag("approval.yes").assertContentDescriptionEquals("Close")
        compose.onNodeWithContentDescription("Decline approval").assertDoesNotExist()
        val oldClose=dev.yab.browser.originalRenderedClick(compose.onNodeWithTag("approval.yes").fetchSemanticsNode())
        compose.runOnIdle {
            oldReady();assertEquals(1,proofs);assertTrue(controller.state.value.deferred.isEmpty())
            port.connection.value=port.connection.value.copy(epoch=1)
            controller.replaceValidated(listOf(request));oldClose()
            assertTrue(controller.state.value.deferred.isEmpty());assertNull(controller.state.value.error)
        }
        compose.onNodeWithTag("approval.yes").assertContentDescriptionEquals("Approve").performClick()
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Same owned error")
        compose.onNodeWithTag("approval.yes").assertContentDescriptionEquals("Close").performClick()
        compose.runOnIdle {
            assertEquals(2,proofs);assertEquals(setOf(request.id),controller.state.value.deferred)
            assertEquals(listOf(request),controller.state.value.requests);assertEquals(0,port.answers)
        }
    }
    @Test fun failedAccountsKeepTheSourceBlankHintAndRefuseOldChoiceOrHeaderUntilFreshFacts() {
        val port=DraftPort();val now=System.currentTimeMillis();val controller=ApprovalController(port){now}
        val request=ApprovalRequest("accounts","account-a","mac",1,now+300_000,"Claude","Owned account","Exact fixture",
            kind=ApprovalKind.ACCOUNTS,choices=listOf("one@example.test"),verb="Sign In")
        var proofs=0
        val gate=object:ApprovalAuthentication { override suspend fun authenticate(reason:String):DeviceAuthenticationProof {
            proofs++;error("Owned account error")
        } }
        controller.replaceValidated(listOf(request))
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller,gate) } }
        val choice=compose.onNodeWithContentDescription("Sign in as one@example.test")
        val oldChoice=dev.yab.browser.originalRenderedClick(choice.fetchSemanticsNode())
        val oldNo=dev.yab.browser.originalRenderedClick(compose.onNodeWithContentDescription("Decline approval").fetchSemanticsNode())
        choice.performClick()
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Owned account error")
        compose.onNodeWithTag("approval.accounts.hint").assertTextEquals("")
        choice.assertIsNotEnabled();compose.onNodeWithTag("approval.yes").assertDoesNotExist()
        compose.onNodeWithContentDescription("Decline approval").assertDoesNotExist()
        val density=androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        compose.onNodeWithText(request.title).performTouchInput {
            down(center);moveBy(androidx.compose.ui.geometry.Offset(0f,150*density),delayMillis=100);up()
        }
        compose.runOnIdle {
            assertEquals(0,port.answers);assertEquals(listOf(request),controller.state.value.requests)
            assertTrue(controller.state.value.deferred.isEmpty())
        }
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Owned account error")
        compose.runOnIdle {
            oldChoice();oldNo();assertEquals(1,proofs);assertEquals(0,port.answers)
            assertTrue(controller.state.value.deferred.isEmpty())
            controller.replaceValidated(listOf(request.copy(revision=2,summary="Fresh exact facts")))
        }
        compose.onNodeWithTag("approval.accounts.hint").assertTextEquals("Tap an account to sign in")
        choice.assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(2,proofs);assertEquals(0,port.answers);assertTrue(controller.state.value.deferred.isEmpty()) }
    }
    @Test fun aReceivedFailureCloseCannotDismissAReplacementEpochResultAndFreshCloseDoesNotAnswer() {
        val port=object:AgentSyncPort {
            override val connection=MutableStateFlow(RemoteConnection("account",listOf(RemoteMac("mac","Mac",true,emptySet()))))
            override val conversations=MutableStateFlow(emptyList<RemoteConversation>())
            override val approvalResults=MutableStateFlow(emptyList<ApprovalResult>())
            val answers=mutableListOf<ApprovalAnswer>();val forgotten=mutableListOf<String>()
            override suspend fun send(command:AgentSendCommand)=AgentSendReceipt()
            override suspend fun stop(owner:RemoteOwner) {}
            override suspend fun delete(owner:RemoteOwner) {}
            override suspend fun answerApproval(answer:ApprovalAnswer) { answers+=answer }
            override fun forgetApprovalResult(id:String) { forgotten+=id }
        }
        val now=System.currentTimeMillis();val controller=ApprovalController(port){now}
        val request=ApprovalRequest("result","account","mac",1,now+300_000,"Claude","Owned payment","Exact fixture",
            kind=ApprovalKind.PAYMENT,payment=ApprovalPayment("store.test","Book","$42"),verb="Pay $42",requestDigest="facts")
        val gate=object:ApprovalAuthentication { override suspend fun authenticate(reason:String)=DeviceAuthenticationProof(now) }
        fun fail()=ApprovalResult(request.id,request.account,request.mac,"facts",ApprovalResultPhase.failed,"Actual owned failure",null,1.0)
        controller.replaceValidated(listOf(request))
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller,gate) } }
        compose.onNodeWithTag("approval.yes").performClick();compose.onNodeWithTag("approval.sending",useUnmergedTree=true).assertExists()
        compose.runOnIdle { port.approvalResults.value=listOf(fail()) }
        compose.onNodeWithTag("approval.yes").assertContentDescriptionEquals("Close")
        val oldClose=dev.yab.browser.originalRenderedClick(compose.onNodeWithTag("approval.yes").fetchSemanticsNode())
        compose.runOnIdle {
            port.connection.value=port.connection.value.copy(epoch=1)
            controller.replaceValidated(listOf(request));oldClose();assertTrue(port.forgotten.isEmpty())
            port.approvalResults.value=emptyList()
        }
        compose.onNodeWithTag("approval.yes").assertContentDescriptionEquals("Pay $42").performClick()
        compose.onNodeWithTag("approval.sending",useUnmergedTree=true).assertExists()
        compose.runOnIdle { port.approvalResults.value=listOf(fail()) }
        compose.onNodeWithTag("approval.yes").assertContentDescriptionEquals("Close").performClick()
        compose.runOnIdle {
            assertEquals(listOf(request.id),port.forgotten);assertEquals(2,port.answers.size)
            assertTrue(port.answers.all{it.approved});assertTrue(controller.state.value.receipts.isEmpty())
        }
    }
    @Test fun sameFactsReadyAfterCancelledRecoveryCannotReviveTheOriginalFooterAction() {
        val port=DraftPort();val now=System.currentTimeMillis();val controller=ApprovalController(port){now}
        val request=ApprovalRequest("ready-aba","account-a","mac",1,now+300_000,"Claude","Same ready facts","Exact fixture",verb="Approve")
        var authentications=0;var cancel=false
        val gate=object:ApprovalAuthentication { override suspend fun authenticate(reason:String):DeviceAuthenticationProof {
            authentications++
            if(cancel) throw kotlinx.coroutines.CancellationException("Owned fixture cancellation")
            error("Same owned error")
        } }
        controller.replaceValidated(listOf(request))
        val displayed=checkNotNull(controller.captureDisplayed(request))
        val generation=controller.state.value.presentationGeneration
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller,gate) } }
        val oldReady=dev.yab.browser.originalRenderedClick(compose.onNodeWithTag("approval.yes").fetchSemanticsNode())
        compose.onNodeWithTag("approval.yes").performClick()
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Same owned error")
        compose.runOnIdle {
            cancel=true
            // Publish a real Controller cancellation recovery, without replacing the
            // displayed facts/account/generation or mutating its private state.
            try { kotlinx.coroutines.runBlocking { controller.answer(request.id,true,gate,displayed=displayed) };fail("Cancellation must propagate") }
            catch (_:kotlinx.coroutines.CancellationException) { }
            cancel=false
            assertEquals(2,authentications);assertNull(controller.state.value.error)
            assertEquals(generation,controller.state.value.presentationGeneration)
            assertTrue(controller.isDisplayedCurrent(displayed));assertEquals(1L,controller.state.value.failureRevision)
        }
        compose.onNodeWithTag("approval.yes").assertContentDescriptionEquals("Approve").assertIsEnabled()
        compose.runOnIdle {
            oldReady();assertEquals(2,authentications);assertTrue(controller.state.value.deferred.isEmpty());assertEquals(0,port.answers)
        }
        compose.onNodeWithTag("approval.yes").performClick()
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Same owned error")
        compose.onNodeWithTag("approval.yes").assertContentDescriptionEquals("Close").performClick()
        compose.runOnIdle {
            assertEquals(3,authentications);assertEquals(2L,controller.state.value.failureRevision)
            assertEquals(setOf(request.id),controller.state.value.deferred);assertEquals(0,port.answers)
        }
    }
    @Test fun equalFailurePublicationCannotRetargetTheCapturedFooterClose() {
        val port=DraftPort();val now=System.currentTimeMillis();val controller=ApprovalController(port){now}
        val request=ApprovalRequest("failure-aba","account-a","mac",1,now+300_000,"Claude","Same failure facts","Exact fixture",verb="Approve")
        var authentications=0
        val gate=object:ApprovalAuthentication { override suspend fun authenticate(reason:String):DeviceAuthenticationProof {
            authentications++;error("Same owned error")
        } }
        controller.replaceValidated(listOf(request))
        val displayed=checkNotNull(controller.captureDisplayed(request))
        val generation=controller.state.value.presentationGeneration
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller,gate) } }
        compose.onNodeWithTag("approval.yes").performClick()
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Same owned error")
        val oldClose=dev.yab.browser.originalRenderedClick(compose.onNodeWithTag("approval.yes").fetchSemanticsNode())
        compose.runOnIdle {
            kotlinx.coroutines.runBlocking { controller.answer(request.id,true,gate,displayed=displayed) }
            assertEquals(2,authentications);assertEquals(2L,controller.state.value.failureRevision)
            assertEquals(generation,controller.state.value.presentationGeneration);assertTrue(controller.isDisplayedCurrent(displayed))
        }
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Same owned error")
        compose.onNodeWithTag("approval.yes").assertContentDescriptionEquals("Close").assertIsEnabled()
        compose.runOnIdle {
            oldClose();assertTrue(controller.state.value.deferred.isEmpty());assertEquals(0,port.answers)
            assertEquals("Same owned error",controller.state.value.error)
        }
        compose.onNodeWithTag("approval.yes").performClick()
        compose.runOnIdle {
            assertEquals(setOf(request.id),controller.state.value.deferred);assertEquals(listOf(request),controller.state.value.requests)
            assertEquals(2,authentications);assertEquals(0,port.answers)
        }
    }
    @Test fun capturedHeaderNoCannotReviveAfterSameFactsFailureRecoveryButFreshNoDispatchesOnce() {
        val port=object:AgentSyncPort {
            override val connection=MutableStateFlow(RemoteConnection("account-a",listOf(RemoteMac("mac","Mac",true,emptySet()))))
            override val conversations=MutableStateFlow(emptyList<RemoteConversation>())
            val answers=mutableListOf<ApprovalAnswer>()
            override suspend fun send(command:AgentSendCommand)=AgentSendReceipt()
            override suspend fun stop(owner:RemoteOwner) { }
            override suspend fun delete(owner:RemoteOwner) { }
            override suspend fun answerApproval(answer:ApprovalAnswer) {
                val ticket=answer.requireCurrentInteraction()
                ticket.withCurrent { answers+=answer }
            }
        }
        val now=System.currentTimeMillis();val controller=ApprovalController(port){now}
        val request=ApprovalRequest("header-aba","account-a","mac",1,now+300_000,"Claude","Original header facts","Exact fixture",verb="Approve")
        var authentications=0;var cancel=false
        val gate=object:ApprovalAuthentication { override suspend fun authenticate(reason:String):DeviceAuthenticationProof {
            authentications++
            if(cancel) throw kotlinx.coroutines.CancellationException("Owned fixture cancellation")
            error("Owned header error")
        } }
        controller.replaceValidated(listOf(request))
        val displayed=checkNotNull(controller.captureDisplayed(request));val generation=controller.state.value.presentationGeneration
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller,gate) } }
        val oldNo=dev.yab.browser.originalRenderedClick(compose.onNodeWithContentDescription("Decline approval").fetchSemanticsNode())
        compose.onNodeWithTag("approval.yes").performClick()
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Owned header error")
        compose.onNodeWithContentDescription("Decline approval").assertDoesNotExist()
        compose.runOnIdle {
            cancel=true
            try { kotlinx.coroutines.runBlocking { controller.answer(request.id,true,gate,displayed=displayed) };fail("Cancellation must propagate") }
            catch (_:kotlinx.coroutines.CancellationException) { }
            cancel=false
            assertEquals(generation,controller.state.value.presentationGeneration);assertTrue(controller.isDisplayedCurrent(displayed))
            assertEquals(1L,controller.state.value.failureRevision);assertNull(controller.state.value.error)
        }
        compose.onNodeWithContentDescription("Decline approval").assertIsEnabled()
        compose.runOnIdle { oldNo() }
        compose.runOnIdle {
            assertEquals(2,authentications);assertTrue(port.answers.isEmpty())
            assertEquals(listOf(request),controller.state.value.requests);assertTrue(controller.state.value.deferred.isEmpty())
        }
        compose.onNodeWithContentDescription("Decline approval").performClick()
        compose.runOnIdle {
            assertEquals(1,port.answers.size);assertFalse(port.answers.single().approved);assertSame(request,port.answers.single().request)
            assertNull(port.answers.single().proof);assertEquals(2,authentications)
            assertTrue(controller.state.value.requests.isEmpty());assertTrue(controller.state.value.receipts.isEmpty())
        }
    }
    @Test fun capturedAccountChoiceCannotReviveAfterSameFactsFailureRecoveryButFreshChoiceAuthenticates() {
        val port=DraftPort();val now=System.currentTimeMillis();val controller=ApprovalController(port){now}
        val request=ApprovalRequest("choice-aba","account-a","mac",1,now+300_000,"Claude","Original account facts","Exact fixture",
            kind=ApprovalKind.ACCOUNTS,choices=listOf("one@example.test"),verb="Sign In")
        var authentications=0;var cancel=false
        val gate=object:ApprovalAuthentication { override suspend fun authenticate(reason:String):DeviceAuthenticationProof {
            authentications++
            if(cancel) throw kotlinx.coroutines.CancellationException("Owned fixture cancellation")
            error("Owned account error")
        } }
        controller.replaceValidated(listOf(request))
        val displayed=checkNotNull(controller.captureDisplayed(request));val generation=controller.state.value.presentationGeneration
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller,gate) } }
        val choice=compose.onNodeWithContentDescription("Sign in as one@example.test")
        val oldChoice=dev.yab.browser.originalRenderedClick(choice.fetchSemanticsNode())
        choice.performClick()
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Owned account error")
        choice.assertIsNotEnabled()
        compose.runOnIdle {
            cancel=true
            try { kotlinx.coroutines.runBlocking { controller.answer(request.id,true,gate,choice="one@example.test",displayed=displayed) };fail("Cancellation must propagate") }
            catch (_:kotlinx.coroutines.CancellationException) { }
            cancel=false
            assertEquals(generation,controller.state.value.presentationGeneration);assertTrue(controller.isDisplayedCurrent(displayed))
            assertEquals(1L,controller.state.value.failureRevision);assertNull(controller.state.value.error)
        }
        choice.assertIsEnabled();compose.onNodeWithTag("approval.accounts.hint").assertTextEquals("Tap an account to sign in")
        compose.runOnIdle { oldChoice() }
        compose.runOnIdle {
            assertEquals(2,authentications);assertEquals(0,port.answers)
            assertEquals(listOf(request),controller.state.value.requests);assertTrue(controller.state.value.deferred.isEmpty())
        }
        choice.performClick()
        compose.onNodeWithTag("approval.footLine").assertTextEquals("Owned account error")
        choice.assertIsNotEnabled();compose.onNodeWithTag("approval.accounts.hint").assertTextEquals("")
        compose.runOnIdle {
            assertEquals(3,authentications);assertEquals(2L,controller.state.value.failureRevision);assertEquals(0,port.answers)
            assertEquals(listOf(request),controller.state.value.requests);assertTrue(controller.state.value.deferred.isEmpty())
        }
    }
    @Test fun equalPaymentRequestsNeverCarryCardOrAddressDraftsToAnotherOwner() {
        val port = DraftPort()
        val controller = ApprovalController(port)
        val payment = ApprovalPayment("fixture.test", "Fixture item", "$42", takesCard = true, takesPlace = true)
        val request = ApprovalRequest("00000000-0000-0000-0000-000000000061", "account-a", "mac", 1,
            System.currentTimeMillis() + 300_000, "Claude", "Fixture payment", "Synthetic draft only", ApprovalKind.PAYMENT, payment = payment)
        controller.replaceValidated(listOf(request))
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller, null) } }
        fun openDraft() {
            compose.onNodeWithText("Use a new card").performScrollTo().performClick()
            compose.onNodeWithText("Use a new address").performScrollTo().performClick()
        }
        fun type(label: String, value: String) { compose.onNodeWithText(label).performScrollTo().performTextInput(value) }
        fun empty(label: String) {
            val node = compose.onNodeWithText(label).performScrollTo().fetchSemanticsNode()
            assertEquals("$label must not carry a prior request's draft", "", node.config[SemanticsProperties.EditableText].text)
        }
        openDraft()
        type("Card number", "11112222"); type("Security code", "123")
        type("Street", "Fixture Street A"); type("City", "Fixture City A")
        val next = request.copy(id = "00000000-0000-0000-0000-000000000062")
        compose.runOnIdle { controller.replaceValidated(listOf(next)) }
        openDraft()
        empty("Card number"); empty("Security code"); empty("Street"); empty("City")
        type("Card number", "33334444"); type("Security code", "456")
        type("Street", "Fixture Street B"); type("City", "Fixture City B")
        compose.runOnIdle {
            port.connection.value = RemoteConnection("account-b", listOf(RemoteMac("mac", "Mac", true, emptySet())))
            controller.replaceValidated(listOf(next.copy(account = "account-b")))
        }
        openDraft()
        empty("Card number"); empty("Security code"); empty("Street"); empty("City")
        type("Card number", "55556666"); type("Security code", "789")
        type("Street", "Fixture Street C"); type("City", "Fixture City C")
        compose.runOnIdle {
            port.connection.value = port.connection.value.copy(epoch = 1)
            controller.replaceValidated(listOf(next.copy(account = "account-b")))
        }
        openDraft()
        empty("Card number"); empty("Security code"); empty("Street"); empty("City")
    }
    @Test fun equalFilePreviewsCollapseBeforeAnotherAccountIsPresented() {
        val port = DraftPort()
        val controller = ApprovalController(port)
        val bytes = java.io.ByteArrayOutputStream().use { output ->
            val bitmap = android.graphics.Bitmap.createBitmap(1, 1, android.graphics.Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(android.graphics.Color.RED)
                check(bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, output))
                output.toByteArray()
            } finally { bitmap.recycle() }
        }
        val file = ApprovalFile("picture", "Fixture.jpg", "image/jpeg", 1000, pages = 1, previewPages = 1)
        val request = ApprovalRequest("00000000-0000-0000-0000-000000000063", "account-a", "mac", 1,
            System.currentTimeMillis() + 300_000, "Claude", "Fixture upload", "Synthetic preview only", ApprovalKind.FILES,
            files = listOf(file), previews = listOf(ApprovalPreview(file.id, 0, java.util.Base64.getEncoder().encodeToString(bytes))))
        controller.replaceValidated(listOf(request))
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller, null) } }
        compose.onNodeWithText("Fixture.jpg · 1 KB · 1 pages").performScrollTo().performClick()
        compose.waitUntil(5000) { compose.onAllNodesWithContentDescription("Fixture.jpg, page 1").fetchSemanticsNodes().size == 1 }
        compose.runOnIdle {
            port.connection.value = RemoteConnection("account-b", listOf(RemoteMac("mac", "Mac", true, emptySet())))
            controller.replaceValidated(listOf(request.copy(account = "account-b")))
        }
        compose.onNodeWithText("Fixture.jpg · 1 KB · 1 pages").assertExists()
        compose.onNodeWithContentDescription("Fixture.jpg, page 1").assertDoesNotExist()
    }
    @Test fun aQueuedDisplayedActionCannotApproveNewEqualIdFactsOrReconnect() {
        val port = object : AgentSyncPort {
            override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, emptySet()))))
            override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
            var answers = 0
            override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
            override suspend fun stop(owner: RemoteOwner) {}
            override suspend fun delete(owner: RemoteOwner) {}
            override suspend fun answerApproval(answer: ApprovalAnswer) { answers++ }
        }
        var authentications = 0
        val gate = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
                authentications++; return DeviceAuthenticationProof(System.currentTimeMillis())
            }
        }
        val controller = ApprovalController(port)
        val request = ApprovalRequest("00000000-0000-0000-0000-000000000064", "account", "mac", 1,
            System.currentTimeMillis() + 300_000, "Claude", "Original displayed question", "Synthetic facts")
        controller.replaceValidated(listOf(request))
        compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { ApprovalPrompt(controller, gate) } }
        compose.onNodeWithText(request.title).assertExists()
        lateinit var oldFacts: ApprovalDisplayLease
        val changed = request.copy(title = "Changed equal-ID question")
        compose.runOnIdle {
            oldFacts = checkNotNull(controller.captureDisplayed(request))
            controller.replaceValidated(listOf(changed))
        }
        compose.onNodeWithText(changed.title).assertExists()
        compose.runOnIdle {
            kotlinx.coroutines.runBlocking { controller.answer(request.id, true, gate, displayed = oldFacts) }
            assertEquals(0, authentications); assertEquals(0, port.answers)
            val oldEpoch = checkNotNull(controller.captureDisplayed(changed))
            port.connection.value = port.connection.value.copy(epoch = 1)
            controller.replaceValidated(listOf(changed))
            kotlinx.coroutines.runBlocking { controller.answer(request.id, false, gate, displayed = oldEpoch) }
            assertEquals(0, port.answers); assertNull(controller.state.value.error)
        }
        compose.onNodeWithText(changed.title).assertExists()
        compose.onNodeWithText("Approve").performClick()
        compose.runOnIdle { assertEquals(1, authentications); assertEquals(1, port.answers) }
    }
}

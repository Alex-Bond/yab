package dev.yab.agent

import dev.yab.core.sync.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ApprovalParityTest {
    private val request = ApprovalRequest("00000000-0000-0000-0000-000000000050", "account", "mac", 1, 20_000, "Claude", "Read mail?", "In this chat", requestDigest = "digest")
    private class Port : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override val approvalResults = MutableStateFlow(emptyList<ApprovalResult>())
        val answers = mutableListOf<ApprovalAnswer>()
        val forgotten = mutableListOf<String>()
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) { answers += answer }
        override fun forgetApprovalResult(id: String) { forgotten += id }
    }
    private fun result(phase: String, writer: String = "mac", id: String = request.id): Record = Record("assistantresult", request.id).updated(buildJsonObject { put("body", buildJsonObject {
        put("id", id); put("phase", phase); put("words", "Actual Mac words"); put("order", "Order42"); put("at", 1234.5)
    }.toString()) }, Clock(writer))
    @Test fun actualResultRequiresRetainedOwnerAndNeverTreatsApprovalAsPayment() {
        assertNull(ApprovalResultCodec.read(result("paid", "other-mac"), request))
        assertNull(ApprovalResultCodec.read(result("paid", id = "another-question"), request))
        assertNull(ApprovalResultCodec.read(result("invented"), request))
        assertEquals(ApprovalResultPhase.paying, ApprovalResultCodec.read(result("paying"), request)!!.phase)
        assertEquals("Order42", ApprovalResultCodec.read(result("paid"), request)!!.order)
    }
    @Test fun laterAndReopenCannotReuseAnAuthenticationFromAnOldPresentation() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }
        controller.replaceValidated(listOf(request))
        val gate = object : ApprovalAuthentication { override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
            controller.later(request.id); controller.select(request.id); return DeviceAuthenticationProof(1000)
        } }
        controller.answer(request.id, true, gate)
        assertTrue(port.answers.isEmpty())
    }
    @Test fun resultReceiptsExpiryAndOwnerWithdrawalAreExplicit() = runBlocking {
        var now = 1000L
        val port = Port(); val controller = ApprovalController(port) { now }
        val observer = launch(start = CoroutineStart.UNDISPATCHED) { controller.observe() }
        try {
        controller.replaceValidated(listOf(request))
        controller.answer(request.id, true, object : ApprovalAuthentication { override suspend fun authenticate(reason: String) = DeviceAuthenticationProof(now) })
        assertNull(controller.state.value.receipts.single().result)
        val actual = ApprovalResultCodec.read(result("paid"), request)!!
        controller.replaceResults(listOf(actual)); assertEquals(actual, controller.state.value.receipts.single().result)
        now = 50_000; controller.expire(); assertTrue(controller.state.value.receipts.isEmpty())
        controller.replaceValidated(listOf(request)); assertTrue(controller.state.value.requests.isEmpty())
        val current = request.copy(expiresAt = 100_000)
        controller.replaceValidated(listOf(current))
        controller.answer(current.id, true, object : ApprovalAuthentication { override suspend fun authenticate(reason: String) = DeviceAuthenticationProof(now) })
        assertEquals(1, controller.state.value.receipts.size)
        port.connection.value = RemoteConnection("another-account"); yield(); assertTrue(controller.state.value.receipts.isEmpty())
        } finally { observer.cancelAndJoin() }
    }
    @Test fun semanticKindsKeepIncomingMailAndScopedReadDistinctFromSending() {
        val incoming = ApprovalMail("Sender", listOf("Me"), "Received", "Body", date = 1234.0)
        assertEquals(ApprovalKind.MAIL_BATCH, ApprovalSemantics.kind("mail.change", null, listOf(incoming), emptyList(), null, null, emptyList()))
        assertEquals(ApprovalKind.MAIL_SEARCH, ApprovalSemantics.kind("mail.read", null, emptyList(), emptyList(), null, "Search terms", emptyList()))
        assertEquals(ApprovalKind.MESSAGE, ApprovalSemantics.kind("messages.send", null, emptyList(), emptyList(), "Anna", "Exact body", emptyList()))
        val pdf = ApprovalFile("pdf", "Long.pdf", "application/pdf", 123, pages = 150, previewPages = 3)
        assertEquals(150, pdf.pages); assertEquals(3, pdf.previewPages)
    }
    @Test fun authenticationCannotAuthorizeReplacedFactsExpiryOrWithdrawnOwner() = runBlocking {
        for (transition in 0..2) {
            var now = 1000L
            val port = Port()
            val controller = ApprovalController(port) { now }
            controller.replaceValidated(listOf(request))
            val gate = object : ApprovalAuthentication {
                override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
                    when (transition) {
                        // A changed rendered fact must invalidate even an unchanged revision.
                        0 -> controller.replaceValidated(listOf(request.copy(summary = "Changed search scope")))
                        1 -> { now = request.expiresAt; controller.expire() }
                        // Refusal removes the current questions and known Macs in the real bridge.
                        2 -> { port.connection.value = RemoteConnection("account", epoch = 1); controller.replaceValidated(emptyList()) }
                    }
                    return DeviceAuthenticationProof(now)
                }
            }
            controller.answer(request.id, true, gate)
            assertTrue("Transition $transition must not send the old answer", port.answers.isEmpty())
            assertNull("An old authentication cannot publish errors into a replacement or withdrawn presentation", controller.state.value.error)
            assertNull(controller.state.value.busy)
            if (transition == 0) {
                val fresh = request.copy(summary = "Changed search scope")
                val freshLease = checkNotNull(controller.captureDisplayed(fresh)); var freshProofs = 0
                controller.answer(fresh.id, true, object : ApprovalAuthentication {
                    override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
                        freshProofs++; return DeviceAuthenticationProof(now)
                    }
                }, displayed = freshLease)
                assertEquals(1, freshProofs); assertEquals(fresh, port.answers.single().request)
            }
        }
    }
    @Test fun sameAccountReconnectCannotReuseAuthenticationOrAnOldReceiptTimer() = runTest {
        val port = Port()
        val controller = ApprovalController(port) { testScheduler.currentTime }
        backgroundScope.launch { controller.observe() }
        runCurrent()
        val original = request.copy(expiresAt = 200_000, sourceEpoch = 0)
        controller.replaceValidated(listOf(original))
        val resume = CompletableDeferred<Unit>()
        val operation = launch {
            controller.answer(original.id, true, object : ApprovalAuthentication {
                override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
                    resume.await()
                    return DeviceAuthenticationProof(testScheduler.currentTime)
                }
            })
        }
        runCurrent()
        assertEquals(original.id, controller.state.value.busy)
        port.connection.value = port.connection.value.copy(epoch = 1)
        runCurrent()
        val current = original.copy(sourceEpoch = 1)
        controller.replaceValidated(listOf(current))
        resume.complete(Unit); operation.join()
        assertTrue(port.answers.isEmpty())
        assertNull(controller.state.value.error)
        assertNull(controller.state.value.busy)
        assertEquals(1L, controller.state.value.ownerEpoch)
        assertEquals(current, controller.state.value.requests.single())

        val gate = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String) = DeviceAuthenticationProof(testScheduler.currentTime)
        }
        controller.answer(current.id, true, gate)
        runCurrent()
        assertEquals(1L, port.answers.single().expectedEpoch)
        // The old nonpayment timer must not remove a new owner's same-ID payment.
        port.connection.value = port.connection.value.copy(epoch = 2)
        runCurrent()
        val reconnected = current.copy(sourceEpoch = 2, kind = ApprovalKind.PAYMENT,
            payment = ApprovalPayment("fixture.test", "Synthetic item", "$42"))
        controller.replaceValidated(listOf(reconnected))
        controller.answer(reconnected.id, true, gate)
        runCurrent()
        advanceTimeBy(650); runCurrent()
        assertEquals(reconnected, controller.state.value.receipts.single().request)
        assertTrue(port.forgotten.isEmpty())
    }
    @Test fun typedReceiptDeadlinesAdvanceTheQuestionQueueWithoutInventingCompletion() = runTest {
        val port = Port()
        val controller = ApprovalController(port) { testScheduler.currentTime }
        backgroundScope.launch { controller.observe() }
        runCurrent()
        val next = request.copy(id = "00000000-0000-0000-0000-000000000051", expiresAt = 200_000)
        val gate = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String) = DeviceAuthenticationProof(testScheduler.currentTime)
        }
        val plain = request.copy(expiresAt = 200_000)
        controller.replaceValidated(listOf(plain, next))
        controller.answer(plain.id, true, gate); runCurrent()
        advanceTimeBy(649); runCurrent()
        assertNull(controller.state.value.receipts.single().result)
        advanceTimeBy(1); runCurrent()
        assertTrue(controller.state.value.receipts.isEmpty())
        assertEquals(next, controller.state.value.requests.single())
        assertEquals(listOf(plain.id), port.forgotten)

        val pay = plain.copy(kind = ApprovalKind.PAYMENT, payment = ApprovalPayment("fixture.test", "Synthetic item", "$42"))
        controller.replaceValidated(listOf(pay, next))
        controller.answer(pay.id, true, gate); runCurrent()
        advanceTimeBy(44_999); runCurrent()
        assertNull(controller.state.value.receipts.single().result)
        advanceTimeBy(1); runCurrent()
        assertTrue(controller.state.value.receipts.isEmpty())
        assertEquals(next, controller.state.value.requests.single())

        controller.replaceValidated(listOf(pay, next))
        controller.answer(pay.id, true, gate); runCurrent()
        val paid = ApprovalResult(pay.id, pay.account, pay.mac, checkNotNull(pay.requestDigest), ApprovalResultPhase.paid,
            "Controlled owned result", "FixtureOrder", 1234.0)
        controller.replaceResults(listOf(paid)); runCurrent()
        advanceTimeBy(1099); runCurrent()
        assertEquals(paid, controller.state.value.receipts.single().result)
        advanceTimeBy(1); runCurrent()
        assertTrue(controller.state.value.receipts.isEmpty())
        assertEquals(next, controller.state.value.requests.single())
    }
    @Test fun queuedUiActionsCannotAuthenticateUnseenFactsOrAReconnectedOwner() = runTest {
        for (transition in 0..3) {
            val port = Port()
            val controller = ApprovalController(port) { 1000 }
            controller.replaceValidated(listOf(request))
            val displayed = checkNotNull(controller.captureDisplayed(request))
            var authentications = 0
            val gate = object : ApprovalAuthentication {
                override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
                    authentications++; return DeviceAuthenticationProof(1000)
                }
            }
            val tapped = launch { controller.answer(request.id, true, gate, displayed = displayed) }
            // This runs before the queued UI coroutine starts, not inside authentication.
            when (transition) {
                0 -> controller.replaceValidated(listOf(request.copy(summary = "Unseen equal-ID facts")))
                1 -> { port.connection.value = port.connection.value.copy(epoch = 1); controller.replaceValidated(listOf(request)) }
                2 -> { controller.later(request.id); controller.select(request.id) }
                else -> { port.connection.value = RemoteConnection("another-account"); controller.replaceValidated(emptyList()) }
            }
            tapped.join()
            assertEquals("No authentication for stale presentation $transition", 0, authentications)
            assertTrue(port.answers.isEmpty())
            assertNull(controller.state.value.busy)
            assertNull(controller.state.value.error)
            controller.later(request.id, displayed)
            assertTrue(controller.state.value.deferred.isEmpty())
        }
        val port = Port(); val controller = ApprovalController(port) { 1000 }
        controller.replaceValidated(listOf(request))
        val shown = checkNotNull(controller.captureDisplayed(request))
        controller.answer(request.id, true, object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String) = DeviceAuthenticationProof(1000)
        }, displayed = shown)
        assertEquals(request, port.answers.single().request)
    }
}

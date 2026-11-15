package dev.yab.agent

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ApprovalRetryParityTest {
    private val payment = ApprovalPayment("store.test", "Book", "$42", cards = listOf(
        ApprovalCard("a", "Visa", "1111", "First"), ApprovalCard("b", "Mastercard", "2222", "Second")), card = "a", takesCard = true)
    private val first = ApprovalRequest("first", "account", "mac", 1, 90_000, "Claude", "Pay?", "Exact facts",
        kind = ApprovalKind.PAYMENT, payment = payment, requestDigest = "first-digest", detailDigest = "first-detail",
        place = "chat:owned", sourceEpoch = 0, sourceSession = "actual-session", sourceIssuedAt = 1.0)
    private class Port : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        val answers = mutableListOf<ApprovalAnswer>()
        val forgotten = mutableListOf<String>()
        val retained = linkedMapOf<String, ApprovalRequest>()
        var afterAnswer: (suspend (ApprovalAnswer) -> Unit)? = null
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) {
            answers += answer
            if (answer.approved) retained[answer.request.id] = answer.request
            afterAnswer?.invoke(answer)
        }
        override fun forgetApprovalResult(id: String) { forgotten += id; retained.remove(id) }
    }
    private val gate = object : ApprovalAuthentication { override suspend fun authenticate(reason: String) = DeviceAuthenticationProof(1000) }
    private suspend fun declined(controller: ApprovalController): ApprovalReceipt {
        controller.replaceValidated(listOf(first))
        controller.answer(first.id, true, gate, picks = ApprovalPicks(card = "b"), displayed = controller.captureDisplayed(first))
        controller.replaceResults(listOf(ApprovalResult(first.id, first.account, first.mac, "first-digest", ApprovalResultPhase.declined, "Site refused", null, 1.0)))
        return controller.state.value.receipts.single()
    }
    private fun next() = first.copy(id = "retry", revision = 2, payment = payment.copy(amount = "$43"),
        requestDigest = "retry-digest", detailDigest = "retry-detail", sourceIssuedAt = 2.0)

    @Test fun sameActualContextRetryKeepsOnlyStillOfferedPicksAndAuthenticatesFreshFacts() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }
        val receipt = declined(controller)
        val next = next(); controller.replaceValidated(listOf(next))
        assertEquals(next, controller.retryRequest(receipt))
        val lease = checkNotNull(controller.captureDisplayed(next))
        val picks = receipt.picks.forRetry(checkNotNull(next.payment))
        assertEquals("b", picks.card)
        controller.answer(next.id, true, gate, picks = picks, displayed = lease)
        assertEquals(listOf(first, next), port.answers.map { it.request })
        assertEquals("b", port.answers.last().picks.card)
        assertEquals(listOf(first.id), port.forgotten)
        assertEquals(listOf(next.id), controller.state.value.receipts.map { it.request.id })
        val missing = payment.copy(cards = payment.cards.take(1))
        assertEquals("a", receipt.picks.forRetry(missing).card)
        assertNull(receipt.picks.forRetry(payment.copy(takesCard = false)).card)
    }

    @Test fun foreignSessionPlaceMacEpochExpiryAndMissingSessionCannotBorrowDeclinedDraft() = runBlocking {
        for (change in listOf<(ApprovalRequest) -> ApprovalRequest>(
            { it.copy(sourceSession = "other-session") }, { it.copy(sourceSession = null) }, { it.copy(place = "chat:other") },
            { it.copy(mac = "other-mac") }, { it.copy(sourceEpoch = 1) }, { it.copy(account = "other-account") }, { it.copy(expiresAt = 1000) })) {
            val port = Port(); val controller = ApprovalController(port) { 1000 }; val receipt = declined(controller)
            val candidate = change(next()); controller.replaceValidated(listOf(candidate))
            assertNull(controller.retryRequest(receipt))
            assertNull(controller.captureDisplayed(candidate))
            assertEquals(1, port.answers.size)
        }
    }

    @Test fun replacementDuringRetryAuthenticationCannotApproveOrDiscardTheRetainedDecline() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }; val receipt = declined(controller)
        val next = next(); controller.replaceValidated(listOf(next)); val lease = checkNotNull(controller.captureDisplayed(next))
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val blocked = object : ApprovalAuthentication { override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
            entered.complete(Unit); release.await(); return DeviceAuthenticationProof(1000)
        } }
        val answer = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(next.id, true, blocked,
            picks = receipt.picks.forRetry(checkNotNull(next.payment)), displayed = lease) }
        entered.await(); controller.replaceValidated(listOf(next.copy(payment = payment.copy(amount = "$99"), detailDigest = "changed")))
        release.complete(Unit); answer.await()
        assertEquals(1, port.answers.size)
        assertEquals(listOf(receipt), controller.state.value.receipts)
        assertTrue(port.forgotten.isEmpty())
    }

    @Test fun twoQueuedAccountRowsCannotAuthenticateOrSendTwice() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }
        val signIn = first.copy(kind = ApprovalKind.ACCOUNTS, payment = null, choices = listOf("first", "second"))
        controller.replaceValidated(listOf(signIn)); val lease = checkNotNull(controller.captureDisplayed(signIn))
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>(); var proofs = 0
        val blocked = object : ApprovalAuthentication { override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
            proofs++; entered.complete(Unit); release.await(); return DeviceAuthenticationProof(1000)
        } }
        val firstTap = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(signIn.id, true, blocked, choice = "second", displayed = lease) }
        entered.await()
        controller.answer(signIn.id, true, blocked, choice = "first", displayed = lease)
        assertEquals(1, proofs); assertTrue(port.answers.isEmpty())
        release.complete(Unit); firstTap.await()
        assertEquals(listOf("second"), port.answers.map { it.choice })
    }

    @Test fun freshContextRetryKeepsThePresentedTrayWhileAnUnrelatedQuestionStillExits() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }; val receipt = declined(controller)
        val oldKey = ApprovalPresentationKey(first.account, 0, first.mac, first.id, first.fingerprint(), 1)
        val old = ApprovalPresented(oldKey, first, receipt = receipt)
        val tray = ApprovalTrayPresentation()
        tray.offer(old, { true }, false); tray.measure(oldKey, 300.0)
        repeat(180) { tray.advance(1.0 / 120) }
        val before = tray.frame.value
        val next = next(); controller.replaceValidated(listOf(next))
        val lease = checkNotNull(controller.captureDisplayed(next))
        val fresh = ApprovalPresented(oldKey.copy(id = next.id, facts = next.fingerprint()), next, action = lease, retry = receipt)
        tray.offer(fresh, { true }, false)
        assertEquals(fresh, tray.frame.value.content)
        assertEquals(ApprovalTravel.READY, tray.frame.value.phase)
        assertEquals(before.rise, tray.frame.value.rise, 0.0)
        assertEquals(before.height, tray.frame.value.height, 0.0)
        assertTrue(tray.frame.value.interactive)
        val foreign = next.copy(id = "unrelated", sourceSession = "foreign-session")
        tray.offer(ApprovalPresented(oldKey.copy(id = foreign.id, facts = foreign.fingerprint()), foreign), { true }, false)
        assertEquals(fresh, tray.frame.value.content)
        assertEquals(ApprovalTravel.LEAVING, tray.frame.value.phase)
    }

    @Test fun acceptedOldAnswerCannotRemoveEqualIdReplacementOrForgetItsRetainedDecline() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }; val receipt = declined(controller)
        val next = next(); controller.replaceValidated(listOf(next)); val lease = checkNotNull(controller.captureDisplayed(next))
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        port.afterAnswer = { entered.complete(Unit); release.await() }
        val answer = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(next.id, true, gate,
            picks = receipt.picks.forRetry(checkNotNull(next.payment)), displayed = lease) }
        entered.await()
        val replacement = next.copy(payment = payment.copy(amount = "$99"), detailDigest = "newer-detail")
        controller.replaceValidated(listOf(replacement)); release.complete(Unit); answer.await()
        assertEquals(listOf(replacement), controller.state.value.requests)
        assertEquals(listOf(receipt), controller.state.value.receipts)
        assertNotNull(controller.captureDisplayed(replacement))
        assertTrue(port.forgotten.isEmpty()); assertNull(controller.state.value.busy); assertNull(controller.state.value.error)
    }

    @Test fun exactOriginalWithdrawalDuringAcceptedDispatchStillCreatesReceiptAndKeepsQueue() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }; val receipt = declined(controller)
        val next = next(); val queued = first.copy(id = "later", sourceSession = "other-context", sourceIssuedAt = 3.0)
        controller.replaceValidated(listOf(next, queued)); val lease = checkNotNull(controller.captureDisplayed(next))
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        port.afterAnswer = { entered.complete(Unit); release.await() }
        val answer = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(next.id, true, gate,
            picks = receipt.picks.forRetry(checkNotNull(next.payment)), displayed = lease) }
        entered.await(); controller.replaceValidated(listOf(queued)); release.complete(Unit); answer.await()
        assertEquals(listOf(queued), controller.state.value.requests)
        assertEquals(listOf(next), controller.state.value.receipts.map { it.request })
        assertEquals(listOf(first.id), port.forgotten)
        assertNull(controller.state.value.busy); assertNull(controller.state.value.error)
    }

    @Test fun staleTransportErrorAndFinallyCannotClearNewPresentationsBusyOrPublishItsError() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }; val receipt = declined(controller)
        val next = next(); controller.replaceValidated(listOf(next)); val oldLease = checkNotNull(controller.captureDisplayed(next))
        val oldEntered = CompletableDeferred<Unit>(); val oldRelease = CompletableDeferred<Unit>()
        port.afterAnswer = { if (it.request == next) { oldEntered.complete(Unit); oldRelease.await(); error("Old transport failure") } }
        val old = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(next.id, true, gate, displayed = oldLease) }
        oldEntered.await()
        val replacement = next.copy(payment = payment.copy(amount = "$99"), detailDigest = "newer-detail")
        controller.replaceValidated(listOf(replacement)); val newLease = checkNotNull(controller.captureDisplayed(replacement))
        val newEntered = CompletableDeferred<Unit>(); val newRelease = CompletableDeferred<Unit>()
        val blockedGate = object : ApprovalAuthentication { override suspend fun authenticate(reason: String): DeviceAuthenticationProof {
            newEntered.complete(Unit); newRelease.await(); return DeviceAuthenticationProof(1000)
        } }
        val fresh = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(replacement.id, true, blockedGate, displayed = newLease) }
        newEntered.await(); oldRelease.complete(Unit); old.await()
        assertEquals(replacement.id, controller.state.value.busy)
        assertNull(controller.state.value.error); assertEquals(listOf(receipt), controller.state.value.receipts)
        assertTrue(port.forgotten.isEmpty())
        newRelease.complete(Unit); fresh.await()
        assertEquals(replacement, port.answers.last().request)
        assertNull(controller.state.value.busy); assertNull(controller.state.value.error)
    }

    @Test fun equalIdRetryKeepsFreshPositiveResultBindingAndCanForgetAnActualDecline() = runBlocking {
        for (approved in listOf(true, false)) {
            val port = Port(); val controller = ApprovalController(port) { 1000 }; val receipt = declined(controller)
            val next = next().copy(id = first.id)
            controller.replaceValidated(listOf(next)); val lease = checkNotNull(controller.captureDisplayed(next))
            controller.answer(next.id, approved, gate, picks = receipt.picks.forRetry(checkNotNull(next.payment)), displayed = lease)
            assertEquals(next, port.answers.last().request)
            if (approved) {
                assertEquals(next, port.retained[next.id]); assertTrue(port.forgotten.isEmpty())
                assertEquals(next, controller.state.value.receipts.single().request)
            } else {
                assertTrue(port.retained.isEmpty()); assertEquals(listOf(first.id), port.forgotten)
                assertTrue(controller.state.value.receipts.isEmpty())
            }
        }
    }

    @Test fun aWithdrawnDispatchFailureCannotPublishAnErrorUnderTheNextQuestion() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }
        val queued = next().copy(id = "queued", sourceSession = "other-session")
        controller.replaceValidated(listOf(first, queued))
        val lease = checkNotNull(controller.captureDisplayed(first))
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        port.afterAnswer = { entered.complete(Unit); release.await(); error("Withdrawn question's transport failure") }
        val answer = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(first.id, true, gate, displayed = lease) }
        entered.await(); controller.replaceValidated(listOf(queued))
        val nextLease = checkNotNull(controller.captureDisplayed(queued))
        assertEquals(first.id, controller.state.value.busy)
        release.complete(Unit); answer.await()
        assertEquals(listOf(queued), controller.state.value.requests)
        assertTrue(controller.isDisplayedCurrent(nextLease)); assertFalse(controller.isDisplayedCurrent(lease))
        assertNull(controller.state.value.error); assertNull(controller.state.value.busy)
        assertTrue(controller.state.value.receipts.isEmpty()); assertTrue(port.forgotten.isEmpty())
        assertEquals(listOf(first), port.answers.map { it.request })
    }

    @Test fun anEarlierArrivingQuestionCannotInheritAnErrorWhileTheSubmittedQuestionStillExists() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }
        controller.replaceValidated(listOf(first))
        val lease = checkNotNull(controller.captureDisplayed(first))
        val generation = controller.state.value.presentationGeneration
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        port.afterAnswer = { entered.complete(Unit); release.await(); error("Now hidden question's transport failure") }
        val answer = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(first.id, true, gate, displayed = lease) }
        entered.await()
        val earlier = next().copy(id = "earlier", sourceSession = "other-session", sourceIssuedAt = .5)
        controller.replaceValidated(listOf(first, earlier))
        val currentLease = checkNotNull(controller.captureDisplayed(earlier))
        assertEquals(generation, controller.state.value.presentationGeneration)
        assertEquals(listOf(earlier, first), controller.state.value.requests)
        assertEquals(first.id, controller.state.value.busy)
        release.complete(Unit); answer.await()
        assertTrue(controller.isDisplayedCurrent(currentLease)); assertFalse(controller.isDisplayedCurrent(lease))
        assertEquals(listOf(earlier, first), controller.state.value.requests)
        assertNull(controller.state.value.error); assertNull(controller.state.value.busy)
        assertTrue(controller.state.value.receipts.isEmpty()); assertTrue(port.forgotten.isEmpty())
    }

    @Test fun aStillDisplayedLiveQuestionKeepsItsOwnTransportErrorAndReleasesBusy() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }
        controller.replaceValidated(listOf(first))
        val lease = checkNotNull(controller.captureDisplayed(first))
        port.afterAnswer = { error("Current question's transport failure") }
        controller.answer(first.id, true, gate, displayed = lease)
        assertEquals("Current question's transport failure", controller.state.value.error)
        assertNull(controller.state.value.busy); assertTrue(controller.isDisplayedCurrent(lease))
        assertEquals(listOf(first), controller.state.value.requests)
        assertTrue(controller.state.value.receipts.isEmpty()); assertTrue(port.forgotten.isEmpty())
        val later = next().copy(id = "later", sourceSession = "other-session")
        controller.replaceValidated(listOf(first, later))
        assertTrue(controller.isDisplayedCurrent(lease))
        assertEquals("Current question's transport failure", controller.state.value.error)
        assertEquals(listOf(first, later), controller.state.value.requests)
    }

    @Test fun anAlreadyPublishedErrorIsClearedWhenAnEarlierQuestionBecomesDisplayed() = runBlocking {
        val port = Port(); val controller = ApprovalController(port) { 1000 }
        controller.replaceValidated(listOf(first))
        val lease = checkNotNull(controller.captureDisplayed(first))
        port.afterAnswer = { error("Previous question's transport failure") }
        controller.answer(first.id, true, gate, displayed = lease)
        assertEquals("Previous question's transport failure", controller.state.value.error)
        assertNull(controller.state.value.busy)
        val generation = controller.state.value.presentationGeneration
        val earlier = next().copy(id = "earlier", sourceSession = "other-session", sourceIssuedAt = .5)
        controller.replaceValidated(listOf(first, earlier))
        val currentLease = checkNotNull(controller.captureDisplayed(earlier))
        assertEquals(generation, controller.state.value.presentationGeneration)
        assertTrue(controller.isDisplayedCurrent(currentLease)); assertFalse(controller.isDisplayedCurrent(lease))
        assertEquals(listOf(earlier, first), controller.state.value.requests)
        assertNull(controller.state.value.error); assertNull(controller.state.value.busy)
        assertTrue(controller.state.value.receipts.isEmpty()); assertTrue(port.forgotten.isEmpty())
    }
}

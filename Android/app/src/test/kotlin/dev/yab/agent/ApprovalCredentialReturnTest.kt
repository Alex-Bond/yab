package dev.yab.agent

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ApprovalCredentialReturnTest {
    private val request = ApprovalRequest("question", "account", "mac", 1, 200_000, "Claude", "Read?", "Original facts",
        choices = listOf("first", "second"), requestDigest = "digest", sourceEpoch = 0)
    private class Port : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        var device = "phone"
        var identityAvailable = true
        val answers = mutableListOf<ApprovalAnswer>()
        override fun approvalAuthenticationIdentity() = connection.value.takeIf { identityAvailable }?.account?.let {
            ApprovalAuthenticationIdentity(it, device, connection.value.epoch)
        }
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) { answer.requireCurrentInteraction(); answers += answer }
    }
    private class Gate(val returned: ApprovalCredentialReturn, private val draft: ApprovalTrayDraft? = null) : ApprovalAuthentication {
        var nonce: String? = null
        var context: ApprovalAuthenticationContext? = null
        override suspend fun authenticate(reason: String): DeviceAuthenticationProof? = error("Context is required")
        override suspend fun authenticateApproval(context: ApprovalAuthenticationContext): DeviceAuthenticationProof? {
            val revision = draft?.revision
            val original = if (draft == null) context else context.withDraft { draft.revision == revision }
            returned.consume(original)?.let { return it }
            this.context = original
            returned.begin(original)?.let { nonce = it }
            return null // This first operation never awaits or returns the separate ActivityResult.
        }
        override fun cancelApprovalAuthentication() { returned.cancel() }
    }
    private class Scene(val request: ApprovalRequest, val draft: ApprovalTrayDraft? = null) {
        var now = 1000L
        val port = Port()
        val controller = ApprovalController(port) { now }
        val lifetime = ApprovalInteractionLifetime().apply { resume() }
        private var sequence = 0
        val returned = ApprovalCredentialReturn({ now }, { "launch-${++sequence}" }).apply { resume() }
        val gate = Gate(returned, draft)
        init { controller.replaceValidated(listOf(request)) }
        fun ticket() = checkNotNull(lifetime.capture(lifetime.state.value))
        suspend fun press(ticket: ApprovalInteractionTicket, choice: String? = "second", picks: ApprovalPicks = ApprovalPicks()) =
            controller.answer(request.id, true, gate, choice, picks, controller.captureDisplayed(request), ticket)
        fun stop() { returned.stop(); lifetime.stop() }
        fun resume() { returned.resume(); lifetime.resume() }
        fun review(): ApprovalInteractionTicket = ticket().also { returned.bindReview(returned.state.value.revision, it) }
    }

    @Test fun stopReturnAndLatePinResultRequireANewRenderedPressWithOriginalChoice() = runBlocking {
        for (resultBeforeResume in listOf(true, false)) {
            val scene = Scene(request); val original = scene.ticket()
            scene.press(original)
            assertNull(scene.controller.state.value.busy); assertTrue(scene.port.answers.isEmpty())
            val nonce = checkNotNull(scene.gate.nonce)
            scene.stop(); assertFalse(original.isCurrent())
            if (resultBeforeResume) scene.returned.complete(nonce, true)
            scene.resume()
            if (!resultBeforeResume) scene.returned.complete(nonce, true)
            assertTrue(scene.port.answers.isEmpty()); assertEquals(ApprovalCredentialPhase.CONFIRM, scene.returned.state.value.phase)
            val fresh = scene.review(); scene.press(fresh)
            val answer = scene.port.answers.single()
            assertSame(request, answer.request); assertSame(fresh, answer.interaction)
            assertEquals("second", answer.choice)
            assertEquals(ApprovalAuthenticationIdentity("account", "phone", 0), answer.authenticationIdentity)
            assertEquals(ApprovalCredentialPhase.NONE, scene.returned.state.value.phase)
            // A receipt is not a reusable proof on another click.
            assertNull(scene.returned.consume(checkNotNull(scene.gate.context)))
        }
    }

    @Test fun pauseOnlyReturnCannotConsumeWithOriginalTicketButFreshRenderedTicketCan() = runBlocking {
        for (fresh in listOf(false, true)) {
            val scene = Scene(request); val original = scene.ticket(); scene.press(original)
            scene.lifetime.pause(); scene.returned.pause()
            scene.returned.complete(checkNotNull(scene.gate.nonce), true)
            scene.resume(); assertTrue(original.isCurrent())
            val ticket = if (fresh) scene.review() else original.also { scene.returned.bindReview(scene.returned.state.value.revision, it) }
            val previous = checkNotNull(scene.gate.context)
            val second = ApprovalAuthenticationContext(request, previous.identity, scene.controller.captureDisplayed(request),
                "second", ApprovalPicks(), ticket) { previous.sourceCurrent() }
            assertEquals(fresh, scene.returned.consume(second) != null)
            assertTrue(scene.port.answers.isEmpty()) // Consuming evidence alone writes nothing.
        }
    }

    @Test fun nextBackgroundOrCancelledLaunchCannotCreditALateResultToANewNonce() = runBlocking {
        val scene = Scene(request); scene.press(scene.ticket()); val old = checkNotNull(scene.gate.nonce)
        scene.stop(); scene.resume(); scene.stop(); scene.resume()
        scene.returned.complete(old, true); assertEquals(ApprovalCredentialPhase.NONE, scene.returned.state.value.phase)
        scene.press(scene.ticket()); val fresh = checkNotNull(scene.gate.nonce); assertNotEquals(old, fresh)
        scene.returned.complete(old, true); assertEquals(ApprovalCredentialPhase.PIN, scene.returned.state.value.phase)
        scene.returned.complete(fresh, false); scene.returned.complete(fresh, true)
        assertEquals(ApprovalCredentialPhase.NONE, scene.returned.state.value.phase); assertTrue(scene.port.answers.isEmpty())
    }

    @Test fun identityDeviceAndSameAccountReconnectCannotBorrowOriginalPinEvidence() = runBlocking {
        for (replace in listOf<(Port) -> Unit>({ it.device = "replacement" }, {
            it.connection.value = it.connection.value.copy(epoch = 1)
        }, { it.identityAvailable = false })) {
            val scene = Scene(request); scene.press(scene.ticket()); val nonce = checkNotNull(scene.gate.nonce)
            scene.stop(); replace(scene.port); scene.resume(); scene.returned.complete(nonce, true)
            assertEquals(ApprovalCredentialPhase.NONE, scene.returned.state.value.phase); assertTrue(scene.port.answers.isEmpty())
        }
        val missing = Scene(request); missing.port.identityAvailable = false; missing.press(missing.ticket())
        assertNull(missing.gate.nonce); assertTrue(missing.port.answers.isEmpty())
    }

    @Test fun equalFactsReplacementObjectRemovalAndChangedFactsPermanentlyClearTheReceipt() = runBlocking {
        // An entirely equal StateFlow value is a no-op, including its stored request reference.
        // It must not pretend that a new object was actually presented or that an answer went.
        val unchanged = Scene(request); unchanged.press(unchanged.ticket())
        val unchangedNonce = checkNotNull(unchanged.gate.nonce)
        val equalSnapshot = request.copy()
        assertNotSame(request, equalSnapshot); assertEquals(request, equalSnapshot)
        unchanged.stop(); unchanged.controller.replaceValidated(listOf(equalSnapshot))
        assertSame(request, unchanged.controller.state.value.requests.single())
        unchanged.resume(); unchanged.returned.complete(unchangedNonce, true)
        assertEquals(ApprovalCredentialPhase.CONFIRM, unchanged.returned.state.value.phase)
        assertTrue(unchanged.port.answers.isEmpty())
        unchanged.returned.cancel()

        val equalReplacement = request.copy()
        // A different queue makes the whole state unequal while the displayed facts/generation
        // stay equal. This forces actual adoption of the new reference before the result arrives.
        val queued = request.copy(id = "zz-queued")
        for ((label, replacement) in listOf(
            "adopted equal-facts reference" to listOf(equalReplacement, queued),
            "changed facts" to listOf(request.copy(summary = "Changed")),
            "removed request" to emptyList(),
        )) {
            val scene = Scene(request); scene.press(scene.ticket()); val nonce = checkNotNull(scene.gate.nonce)
            val displayed = checkNotNull(scene.controller.captureDisplayed(request))
            scene.stop(); scene.controller.replaceValidated(replacement)
            if (replacement.firstOrNull() === equalReplacement) {
                val adopted = scene.controller.state.value.requests.first()
                assertSame(equalReplacement, adopted); assertNotSame(request, adopted)
                val freshDisplay = checkNotNull(scene.controller.captureDisplayed(adopted))
                assertEquals(displayed.generation, freshDisplay.generation)
                assertEquals(displayed.fingerprint, freshDisplay.fingerprint)
            }
            assertFalse(label, checkNotNull(scene.gate.context).sourceCurrent())
            scene.resume(); scene.returned.complete(nonce, true)
            assertEquals(label, ApprovalCredentialPhase.NONE, scene.returned.state.value.phase)
            scene.controller.replaceValidated(listOf(request)); scene.returned.complete(nonce, true)
            assertEquals(label, ApprovalCredentialPhase.NONE, scene.returned.state.value.phase)
            assertTrue(label, scene.port.answers.isEmpty())
        }
    }

    @Test fun draftChangesAndRevertingBeforeRecompositionCannotReuseOldCardPicks() = runBlocking {
        val payment = request.copy(choices = emptyList(), kind = ApprovalKind.PAYMENT, payment = ApprovalPayment("shop", "Book", "$42",
            cards = listOf(ApprovalCard("a", "Visa", "1111", "First"), ApprovalCard("b", "Visa", "2222", "Second")), card = "a", takesCard = true))
        val draft = ApprovalTrayDraft(payment); val scene = Scene(payment, draft)
        scene.press(scene.ticket(), null, draft.picks); val nonce = checkNotNull(scene.gate.nonce)
        val original = draft.picks; draft.picks = ApprovalPicks(card = "b"); draft.picks = original
        assertEquals(2L, draft.revision)
        scene.stop(); scene.resume(); scene.returned.complete(nonce, true)
        assertEquals(ApprovalCredentialPhase.NONE, scene.returned.state.value.phase); assertTrue(scene.port.answers.isEmpty())
    }

    @Test fun differentChoiceOrPicksCannotConsumeTheExactOriginalActionReceipt() = runBlocking {
        for (change in listOf<(ApprovalAuthenticationContext, ApprovalInteractionTicket) -> ApprovalAuthenticationContext>(
            { old, ticket -> ApprovalAuthenticationContext(request, old.identity, old.displayed, "first", old.picks, ticket) { old.sourceCurrent() } },
            { old, ticket -> ApprovalAuthenticationContext(request, old.identity, old.displayed, old.choice, ApprovalPicks(place = "other"), ticket) { old.sourceCurrent() } })) {
            val scene = Scene(request); scene.press(scene.ticket()); scene.stop(); scene.resume()
            scene.returned.complete(checkNotNull(scene.gate.nonce), true); val fresh = scene.review()
            assertNull(scene.returned.consume(change(checkNotNull(scene.gate.context), fresh)))
            assertEquals(ApprovalCredentialPhase.NONE, scene.returned.state.value.phase); assertTrue(scene.port.answers.isEmpty())
        }
    }

    @Test fun cancelledDisposedExpiredAndTooOldResultsNeverAcquireWriteAuthority() = runBlocking {
        for (revoke in listOf<(Scene) -> Unit>({ it.returned.cancel() }, { it.returned.dispose() }, { it.now = request.expiresAt })) {
            val scene = Scene(request); scene.press(scene.ticket()); val nonce = checkNotNull(scene.gate.nonce)
            scene.stop(); revoke(scene); scene.resume(); scene.returned.complete(nonce, true)
            assertEquals(ApprovalCredentialPhase.NONE, scene.returned.state.value.phase); assertTrue(scene.port.answers.isEmpty())
        }
        for (age in listOf(-1L, 60_001L)) {
            val scene = Scene(request); scene.press(scene.ticket()); scene.stop(); scene.resume()
            scene.returned.complete(checkNotNull(scene.gate.nonce), true); scene.now += age
            scene.returned.reconcile(); assertEquals(ApprovalCredentialPhase.NONE, scene.returned.state.value.phase)
        }
    }

    @Test fun declineClearsPinReceiptAndStillRequiresFreshStopRevokedNoTicket() = runBlocking {
        val scene = Scene(request); val original = scene.ticket(); scene.press(original)
        scene.stop(); scene.resume(); scene.returned.complete(checkNotNull(scene.gate.nonce), true)
        scene.controller.answer(request.id, false, scene.gate, displayed = scene.controller.captureDisplayed(request), interaction = original)
        assertTrue(scene.port.answers.isEmpty()); assertEquals(ApprovalCredentialPhase.CONFIRM, scene.returned.state.value.phase)
        val fresh = scene.review()
        scene.controller.answer(request.id, false, scene.gate, displayed = scene.controller.captureDisplayed(request), interaction = fresh)
        assertFalse(scene.port.answers.single().approved); assertNull(scene.port.answers.single().proof)
        assertEquals(ApprovalCredentialPhase.NONE, scene.returned.state.value.phase)
    }

    @Test fun readyReceiptSurvivesPauseButTheNextStopOrDisposePermanentlyClearsIt() = runBlocking {
        for (dispose in listOf(false, true)) {
            val scene = Scene(request); scene.press(scene.ticket()); val nonce = checkNotNull(scene.gate.nonce)
            scene.stop(); scene.resume(); scene.returned.complete(nonce, true)
            scene.returned.pause(); scene.lifetime.pause(); scene.resume()
            assertEquals(ApprovalCredentialPhase.CONFIRM, scene.returned.state.value.phase)
            if (dispose) { scene.returned.dispose(); scene.lifetime.dispose() } else { scene.stop(); scene.resume() }
            scene.returned.complete(nonce, true)
            assertEquals(ApprovalCredentialPhase.NONE, scene.returned.state.value.phase); assertTrue(scene.port.answers.isEmpty())
        }
    }

    @Test fun transportForwardsOnlyTheActualIdentityAndLegacyAuthenticatorsKeepTheirDefaultMethod() = runBlocking {
        val scene = Scene(request)
        val transport = SyncProtocolTransport(scene.port)
        assertEquals(ApprovalAuthenticationIdentity("account", "phone", 0), transport.approvalAuthenticationIdentity())
        scene.port.device = "new-phone"
        assertEquals("new-phone", transport.approvalAuthenticationIdentity()?.device)
        var authenticated = 0
        val legacy = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String): DeviceAuthenticationProof { authenticated++; return DeviceAuthenticationProof(1000) }
        }
        scene.controller.answer(request.id, true, legacy, "second", displayed = scene.controller.captureDisplayed(request), interaction = scene.ticket())
        assertEquals(1, authenticated); assertEquals("new-phone", scene.port.answers.single().authenticationIdentity?.device)
    }
}

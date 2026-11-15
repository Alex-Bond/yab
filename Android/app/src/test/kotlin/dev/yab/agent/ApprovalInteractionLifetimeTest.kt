package dev.yab.agent

import dev.yab.core.sync.MemoryJournal
import dev.yab.core.sync.RecordKey
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ApprovalInteractionLifetimeTest {
    private val request = ApprovalRequest("question", "account", "mac", 1, 90_000, "Claude", "Read?", "Original facts",
        requestDigest = "digest", sourceEpoch = 0)
    private class Port : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        val answers = mutableListOf<ApprovalAnswer>()
        var answerWrite: (suspend (ApprovalAnswer) -> Unit)? = null
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) { answerWrite?.invoke(answer) ?: run { answers += answer } }
    }
    private val gate = object : ApprovalAuthentication {
        override suspend fun authenticate(reason: String) = DeviceAuthenticationProof(1000)
    }
    private fun active() = ApprovalInteractionLifetime().apply { resume() }
    private fun ApprovalInteractionLifetime.ticket() = checkNotNull(capture(state.value))

    @Test fun stopAndReturnCannotAdmitALateProofOrReviveTheRenderedCallback() = runTest {
        val port = Port(); val controller = ApprovalController(port) { 1000 }; controller.replaceValidated(listOf(request))
        val lifetime = active(); val ticket = lifetime.ticket()
        val proof = CompletableDeferred<Unit>(); var proofs = 0
        val blocked = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String): DeviceAuthenticationProof = withContext(NonCancellable) {
                proofs++; proof.await(); DeviceAuthenticationProof(1000)
            }
        }
        val action = async { controller.answer(request.id, true, blocked, displayed = controller.captureDisplayed(request), interaction = ticket) }
        runCurrent(); assertEquals(request.id, controller.state.value.busy)
        lifetime.stop(); lifetime.resume(); proof.complete(Unit); runCurrent(); action.join()
        assertTrue(action.isCancelled); assertFalse(ticket.isCurrent()); assertTrue(port.answers.isEmpty())
        assertNull(controller.state.value.busy); assertNull(controller.state.value.error)
        // A callback retained before STOP cannot replace its original ticket after return.
        controller.answer(request.id, true, blocked, interaction = ticket)
        assertEquals(1, proofs)
        controller.answer(request.id, true, gate, displayed = controller.captureDisplayed(request), interaction = lifetime.ticket())
        assertEquals(1, port.answers.size)
    }

    @Test fun queuedProductionAdmissionRejectsBothYesAndNoAfterStopReturn() = runTest {
        for (approved in listOf(true, false)) {
            val lifetime = active(); val captured = lifetime.ticket(); val journal = MemoryJournal("phone") { 1000 }
            val port = Port(); val controller = ApprovalController(port) { 1000 }; controller.replaceValidated(listOf(request))
            val delivered = CompletableDeferred<ApprovalAnswer>(); val releaseQueue = CompletableDeferred<Unit>()
            var refused = false
            port.answerWrite = { answer ->
                delivered.complete(answer)
                // Even a queued transport that ignores cancellation must pass the real authorities.
                withContext(NonCancellable) {
                    releaseQueue.await()
                    withContext(StandardTestDispatcher(testScheduler)) {
                        refused = runCatching {
                            val admitted = answer.requireCurrentInteraction()
                            admitted.withCurrent { journal.changeBatch(mapOf(RecordKey("assistantanswer", request.id) to
                                buildJsonObject { put("yes", approved) }), mapOf(RecordKey("assistantanswer", request.id) to null)) }
                        }.isFailure
                    }
                }
            }
            val queued = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(request.id, approved, gate,
                displayed = controller.captureDisplayed(request), interaction = captured) }
            assertSame(captured, delivered.await().interaction)
            lifetime.stop(); lifetime.resume(); releaseQueue.complete(Unit); runCurrent(); queued.join()
            assertTrue(refused); assertTrue(journal.pending().isEmpty())
        }
    }

    @Test fun revocationAfterBridgeAdmissionStillPreventsTheFinalJournalBatch() = runTest {
        for (approved in listOf(true, false)) {
            val lifetime = active(); val journal = MemoryJournal("phone") { 1000 }
            val answer = ApprovalAnswer(request, approved, null, if (approved) DeviceAuthenticationProof(1000) else null, interaction = lifetime.ticket())
            val admitted = answer.requireCurrentInteraction()
            lifetime.stop(); lifetime.resume()
            assertTrue(runCatching { admitted.withCurrent { journal.changeBatch(mapOf(RecordKey("assistantanswer", request.id) to
                buildJsonObject { put("yes", approved) }), mapOf(RecordKey("assistantanswer", request.id) to null)) } }.isFailure)
            assertTrue(journal.pending().isEmpty())
            val fresh = lifetime.ticket()
            fresh.withCurrent { journal.changeBatch(mapOf(RecordKey("assistantanswer", request.id) to
                buildJsonObject { put("yes", approved) }), mapOf(RecordKey("assistantanswer", request.id) to null)) }
            assertEquals(1, journal.pending().size)
        }
    }

    @Test fun credentialPauseWaitsForSameTicketResumeAndKeepsCapturedChoice() = runTest {
        val port = Port(); val controller = ApprovalController(port) { 1000 }
        val choices = request.copy(choices = listOf("first", "second")); controller.replaceValidated(listOf(choices))
        val lifetime = active(); val captured = lifetime.ticket(); val proof = CompletableDeferred<Unit>()
        val blocked = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String): DeviceAuthenticationProof { proof.await(); return DeviceAuthenticationProof(1000) }
        }
        val action = async { controller.answer(choices.id, true, blocked, choice = "second",
            displayed = controller.captureDisplayed(choices), interaction = captured) }
        runCurrent(); lifetime.pause(); proof.complete(Unit); runCurrent()
        assertFalse(captured.isCurrent()); assertFalse(action.isCompleted); assertTrue(port.answers.isEmpty())
        assertEquals(choices.id, controller.state.value.busy)
        lifetime.resume(); runCurrent(); action.await()
        assertSame(captured, port.answers.single().interaction); assertEquals("second", port.answers.single().choice)
    }

    @Test fun factsChangedDuringCredentialPauseCannotBorrowResumeOrOldPicks() = runTest {
        val port = Port(); val controller = ApprovalController(port) { 1000 }; controller.replaceValidated(listOf(request))
        val lifetime = active(); val captured = lifetime.ticket(); val proof = CompletableDeferred<Unit>()
        val blocked = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String): DeviceAuthenticationProof { proof.await(); return DeviceAuthenticationProof(1000) }
        }
        val action = async { controller.answer(request.id, true, blocked, displayed = controller.captureDisplayed(request), interaction = captured) }
        runCurrent(); lifetime.pause(); proof.complete(Unit); runCurrent()
        controller.replaceValidated(listOf(request.copy(summary = "Changed facts"))); lifetime.resume(); runCurrent(); action.await()
        assertTrue(port.answers.isEmpty()); assertNull(controller.state.value.busy); assertNull(controller.state.value.error)
    }

    @Test fun disposedOwnerAndQueuedRenderedActionCannotTransferToReplacement() = runTest {
        val old = active(); val rendered = ApprovalInteraction(this, old.ticket()); var calls = 0
        val queued = rendered.launch { calls++ }
        assertNotNull(queued); old.dispose()
        val replacement = active(); runCurrent()
        assertEquals(0, calls); assertNull(rendered.launch { calls++ }); assertFalse(rendered.current())
        val fresh = ApprovalInteraction(this, replacement.ticket()).launch { calls++ }
        runCurrent(); checkNotNull(fresh).join(); assertEquals(1, calls)
        // Repeated resume cannot resurrect a disposed authority.
        old.resume(); assertNull(old.capture(old.state.value))
    }

    @Test fun oldCancelledAuthenticationCannotClearFreshReconnectBusy() = runTest {
        val port = Port(); val controller = ApprovalController(port) { 1000 }; controller.replaceValidated(listOf(request))
        val lifetime = active(); val oldProof = CompletableDeferred<Unit>(); val freshProof = CompletableDeferred<Unit>()
        val oldGate = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String): DeviceAuthenticationProof = withContext(NonCancellable) {
                oldProof.await(); DeviceAuthenticationProof(1000)
            }
        }
        val oldTicket = lifetime.ticket()
        val old = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(request.id, true, oldGate,
            displayed = controller.captureDisplayed(request), interaction = oldTicket) }
        lifetime.stop(); lifetime.resume()
        port.connection.value = port.connection.value.copy(epoch = 1)
        val replacement = request.copy(sourceEpoch = 1); controller.replaceValidated(listOf(replacement))
        val freshGate = object : ApprovalAuthentication {
            override suspend fun authenticate(reason: String): DeviceAuthenticationProof { freshProof.await(); return DeviceAuthenticationProof(1000) }
        }
        val fresh = async(start = CoroutineStart.UNDISPATCHED) { controller.answer(replacement.id, true, freshGate,
            displayed = controller.captureDisplayed(replacement), interaction = lifetime.ticket()) }
        oldProof.complete(Unit); runCurrent(); old.join()
        assertTrue(old.isCancelled); assertEquals(replacement.id, controller.state.value.busy); assertTrue(port.answers.isEmpty())
        freshProof.complete(Unit); runCurrent(); fresh.await()
        assertEquals(1L, port.answers.single().expectedEpoch); assertNull(controller.state.value.busy)
    }

    @Test fun productionBridgeAdmissionHasNoMissingTicketBypassWhileFakePortsRemainCompatible() = runTest {
        for (approved in listOf(true, false)) assertTrue(runCatching {
            ApprovalAnswer(request, approved, null, if (approved) DeviceAuthenticationProof(1000) else null).requireCurrentInteraction()
        }.isFailure)
        val port = Port(); val controller = ApprovalController(port) { 1000 }; controller.replaceValidated(listOf(request))
        controller.answer(request.id, false, null)
        assertEquals(1, port.answers.size); assertNull(port.answers.single().interaction)
    }
}

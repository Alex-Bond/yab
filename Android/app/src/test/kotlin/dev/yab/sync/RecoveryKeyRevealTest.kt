package dev.yab.sync

import dev.yab.agent.ApprovalAuthentication
import dev.yab.agent.DeviceAuthenticationProof
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** Controlled authentication results exercise provenance, not biometric hardware acceptance. */
@OptIn(ExperimentalCoroutinesApi::class)
class RecoveryKeyRevealTest {
    private val original = SyncIdentityLease("account", "phone", 7)
    private fun gate(answer: CompletableDeferred<DeviceAuthenticationProof?>) = object : ApprovalAuthentication {
        override suspend fun authenticate(reason: String) = answer.await()
    }

    @Test fun accountDeviceEpochOrRevocationChangedDuringAuthenticationCannotExportAnyKey() = runTest {
        for (changed in listOf(original.copy(account = "other"), original.copy(device = "other"), original.copy(epoch = 8), null)) {
            var source: SyncIdentityLease? = original; var exports = 0
            val controller = RecoveryKeyReveal({ source }, { exports++; "secret" }, { 1000 })
            val authenticated = CompletableDeferred<DeviceAuthenticationProof?>()
            val request = launch { controller.reveal(gate(authenticated)) }; runCurrent()
            assertTrue(controller.state.value.busy); assertNull(controller.state.value.revealed); assertEquals(0, exports)
            source = changed; authenticated.complete(DeviceAuthenticationProof(1000)); request.join()
            assertEquals(0, exports); assertNull(controller.state.value.revealed); assertNull(controller.state.value.error)
            controller.close()
        }
    }

    @Test fun clearingOrClosingWhileExportAwaitsCannotPublishItsLateSecret() = runTest {
        for (closing in listOf(false, true)) {
            val exporting = CompletableDeferred<Unit>(); val result = CompletableDeferred<String>()
            val controller = RecoveryKeyReveal({ original }, { exporting.complete(Unit); result.await() }, { 1000 })
            val request = launch { controller.reveal(gate(CompletableDeferred<DeviceAuthenticationProof?>(DeviceAuthenticationProof(1000)))) }
            runCurrent(); exporting.await()
            if (closing) controller.close() else controller.clear()
            result.complete("late secret"); request.join()
            assertNull(controller.state.value.revealed); assertFalse(controller.state.value.busy)
            controller.close()
        }
    }

    @Test fun aNewPresentationCannotReuseTheOldPresentationAuthenticationEvenForTheSameAccount() = runTest {
        var exports = 0
        val controller = RecoveryKeyReveal({ original }, { exports++; "current secret" }, { 1000 })
        val first = CompletableDeferred<DeviceAuthenticationProof?>(); val second = CompletableDeferred<DeviceAuthenticationProof?>()
        val old = launch { controller.reveal(gate(first)) }; runCurrent()
        controller.clear()
        val current = launch { controller.reveal(gate(second)) }; runCurrent()
        first.complete(DeviceAuthenticationProof(1000)); old.join()
        assertEquals(0, exports); assertTrue(controller.state.value.busy); assertNull(controller.state.value.revealed)
        second.complete(DeviceAuthenticationProof(1000)); current.join()
        assertEquals(1, exports); assertEquals(RecoveryKeyReveal.Revealed(original, "current secret"), controller.state.value.revealed)
        controller.clear(); assertNull(controller.state.value.revealed)
        controller.close()
    }

    @Test fun aSessionChangeAfterExportAndStaleAuthenticationProofBothFailClosed() = runTest {
        var source: SyncIdentityLease? = original
        val changedDuringExport = RecoveryKeyReveal({ source }, { source = original.copy(epoch = 8); "old secret" }, { 1000 })
        changedDuringExport.reveal(gate(CompletableDeferred<DeviceAuthenticationProof?>(DeviceAuthenticationProof(1000))))
        assertNull(changedDuringExport.state.value.revealed)
        var exports = 0
        val staleProof = RecoveryKeyReveal({ original }, { exports++; "secret" }, { 1000 })
        staleProof.reveal(gate(CompletableDeferred<DeviceAuthenticationProof?>(DeviceAuthenticationProof(999))))
        assertEquals(0, exports); assertNull(staleProof.state.value.revealed); assertNotNull(staleProof.state.value.error)
        changedDuringExport.close(); staleProof.close()
    }
}

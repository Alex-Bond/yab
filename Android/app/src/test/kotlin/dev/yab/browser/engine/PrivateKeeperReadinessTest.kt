package dev.yab.browser.engine

import org.junit.Assert.*
import org.junit.Test

class PrivateKeeperReadinessTest {
    @Test fun openingAndIsOpenDoNotAuthorizeClosingTheLastPrivateWindow() {
        val gate = PrivateKeeperReadiness(7, 4_000)
        var closes = 0
        assertTrue(gate.afterReady("tab", 10, { true }, { closes++ }))
        assertEquals(0, closes)
        assertFalse(gate.acknowledge(6, true, 20))
        assertEquals(0, closes)
        assertTrue(gate.acknowledge(7, true, 30))
        assertEquals(1, closes)
        assertEquals(PrivateKeeperReadiness.Phase.READY, gate.phase)
        assertFalse(gate.acknowledge(7, true, 40))
        assertEquals(1, closes)
    }

    @Test fun changedDocumentStateOrAccountCannotCommitAfterTheBlankAcknowledgement() {
        val gate = PrivateKeeperReadiness(7, 4_000)
        var document = 1; var account = 1; var savedState = "old"
        var closes = 0
        gate.afterReady("tab", 10, { document == 1 && account == 1 && savedState == "old" }, { closes++ })
        document = 2; account = 2; savedState = "new"
        gate.acknowledge(7, true, 20)
        assertEquals(0, closes); assertEquals(0, gate.pendingCount)
    }

    @Test fun newestCapturedStateReplacesAnOlderAdmissionForTheSameTab() {
        val gate = PrivateKeeperReadiness(7, 4_000)
        val closed = mutableListOf<String>()
        gate.afterReady("tab", 10, { true }, { closed += "old" })
        gate.afterReady("tab", 20, { true }, { closed += "latest" })
        gate.acknowledge(7, true, 30)
        assertEquals(listOf("latest"), closed)
    }

    @Test fun deadlineFailureAndLogicalCloseEachPreserveOriginalAndRejectLateCallbacks() {
        for (stop in listOf<(PrivateKeeperReadiness) -> Unit>(
            { it.expire(4_000) }, { it.acknowledge(7, false, 20) }, { it.revoke() }
        )) {
            val gate = PrivateKeeperReadiness(7, 4_000)
            var closes = 0
            gate.afterReady("tab", 10, { true }, { closes++ })
            stop(gate)
            assertFalse(gate.acknowledge(7, true, 4_001))
            assertFalse(gate.afterReady("tab", 4_002, { true }, { closes++ }))
            assertEquals(0, closes); assertEquals(0, gate.pendingCount)
        }
    }

    @Test fun closingOneTabOrReplacingOwnerCancelsOnlyItsOwnPendingAdmission() {
        val gate = PrivateKeeperReadiness(7, 4_000)
        val closed = mutableListOf<String>()
        gate.afterReady("removed", 10, { true }, { closed += "removed" })
        gate.afterReady("current", 10, { true }, { closed += "current" })
        gate.cancel("removed")
        gate.acknowledge(7, true, 20)
        assertEquals(listOf("current"), closed)
        val next = PrivateKeeperReadiness(8, 4_000)
        next.afterReady("new-owner", 30, { true }, { closed += "new-owner" })
        assertFalse(next.acknowledge(7, true, 40))
        next.cancelPending(); next.acknowledge(8, true, 50)
        assertEquals(listOf("current"), closed)
    }

    @Test fun aReadyKeeperStillChecksTheCurrentNativeSourceImmediatelyBeforeClose() {
        val gate = PrivateKeeperReadiness(7, 4_000)
        gate.acknowledge(7, true, 20)
        var calls = 0; var closes = 0
        gate.afterReady("tab", 50_000, { ++calls == 1 }, { closes++ })
        assertEquals(0, closes)
        assertEquals(PrivateKeeperReadiness.Phase.READY, gate.phase)
    }

    @Test fun synchronousLogicalLifetimeEndDuringAckCannotCommitTheRemainingOldAdmissions() {
        val gate = PrivateKeeperReadiness(7, 4_000)
        val closed = mutableListOf<String>()
        gate.afterReady("first", 10, { true }, { closed += "first"; gate.revoke() })
        gate.afterReady("late", 10, { true }, { closed += "late" })
        gate.acknowledge(7, true, 20)
        assertEquals(listOf("first"), closed)
        assertEquals(PrivateKeeperReadiness.Phase.REVOKED, gate.phase)
        assertEquals(0, gate.pendingCount)
    }
}

package dev.yab.sync

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class SyncOperationLeaseTest {
    private val unjoined = SyncOperationLease.Source(null, null, 0)

    @Test fun replacingPairingInvalidatesItsQueuedCancellationAndSuccessBeforeTheOldSessionCloses() {
        val operations = SyncOperationLease()
        val old = operations.begin(unjoined)
        var screen = "old code"
        val queuedOldFailure = { if (operations.finish(old, unjoined)) screen = "cancelled" }
        val queuedOldSuccess = { if (operations.finish(old, unjoined)) screen = "old account" }
        val next = operations.begin(unjoined)
        screen = "new code"
        queuedOldFailure(); queuedOldSuccess()
        assertEquals("new code", screen); assertTrue(operations.current(next, unjoined))
        assertTrue(operations.finish(next, unjoined))
        screen = "new account"
        queuedOldFailure(); queuedOldSuccess()
        assertEquals("new account", screen)
        assertFalse("A duplicate callback must not commit twice", operations.finish(next, unjoined))
    }

    @Test fun cancellingAnOldPairingCannotCancelTheRecoveryOrAnotherJoinThatReplacedIt() {
        val operations = SyncOperationLease()
        val pairing = operations.begin(unjoined)
        assertTrue(operations.finish(pairing, unjoined))
        val recovery = operations.begin(unjoined)
        assertFalse(operations.finish(pairing, unjoined))
        assertTrue(operations.current(recovery, unjoined))
        val newPairing = operations.begin(unjoined)
        assertFalse("Recovery verification returned after another join", operations.finish(recovery, unjoined))
        assertTrue(operations.finish(newPairing, unjoined))
    }

    @Test fun lateRemoveSuccessAndErrorCannotClearOrReportIntoTheRejoinedAccount() {
        val operations = SyncOperationLease()
        val original = SyncOperationLease.Source("first", "phone", 7)
        val removing = operations.begin(original)
        var current = original
        var cleared = false
        var error: String? = null
        val queuedRemoveSuccess = { if (operations.finish(removing, current)) cleared = true }
        val queuedRemoveFailure = { if (operations.finish(removing, current)) error = "Old network error" }
        operations.invalidate()
        current = SyncOperationLease.Source("second", "new-phone", 9)
        val joining = operations.begin(current)
        queuedRemoveSuccess(); queuedRemoveFailure()
        assertFalse(cleared); assertNull(error); assertTrue(operations.current(joining, current))
        assertTrue(operations.finish(joining, current))
    }

    @Test fun accountDeviceAndEpochAreAllPartOfTheCapturedSource() {
        val source = SyncOperationLease.Source("account", "phone", 7)
        for (changed in listOf(source.copy(account = "other"), source.copy(device = "other"), source.copy(epoch = 8))) {
            val operations = SyncOperationLease(); val request = operations.begin(source)
            assertFalse(operations.current(request, changed)); assertFalse(operations.finish(request, changed))
            assertTrue("A refused stale callback cannot consume the original lease", operations.current(request, source))
        }
    }

    @Test fun closeInvalidationIsVisibleToVerificationFinishingOnAnotherThread() {
        val operations = SyncOperationLease(); val joining = operations.begin(unjoined)
        val began = CountDownLatch(1); val verified = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val completion = executor.submit<Boolean> {
                began.countDown()
                check(verified.await(5, TimeUnit.SECONDS))
                operations.finish(joining, unjoined)
            }
            assertTrue(began.await(5, TimeUnit.SECONDS))
            operations.invalidate()
            verified.countDown()
            assertFalse("A late successful verification cannot revive a closed join", completion.get(5, TimeUnit.SECONDS))
        } finally { verified.countDown(); executor.shutdownNow() }
    }
}

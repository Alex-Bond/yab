package dev.yab.shield

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ShieldApplyLifetimeTest {
    @Test fun aNativeAttemptTimeoutDoesNotKillTheCollectorBeforeItsNextPort() = runTest {
        val ports = MutableSharedFlow<Int>()
        val results = mutableListOf<Exception?>()
        val collecting = launch {
            ports.collectLatest { port ->
                results += shieldApplyFailure {
                    if (port == 1) withTimeout(100) { awaitCancellation() }
                }
            }
        }
        runCurrent()
        ports.emit(1); advanceTimeBy(101); runCurrent()
        assertTrue(results.single() is TimeoutCancellationException)
        assertTrue(collecting.isActive)
        ports.emit(2); runCurrent()
        assertEquals(2, results.size)
        assertNull(results.last())
        collecting.cancelAndJoin()
    }

    @Test fun retiringTheOwnerNeverPublishesACancellationAsAConfigurationError() = runTest {
        var returned = false
        val owner = launch {
            shieldApplyFailure { awaitCancellation() }
            returned = true
        }
        runCurrent(); owner.cancelAndJoin()
        assertFalse(returned)
    }

    @Test fun replacingAnInFlightPolicyCannotPublishItsOldResult() = runTest {
        val policies = MutableSharedFlow<Int>()
        val completed = mutableListOf<Int>()
        val collecting = launch {
            policies.collectLatest { policy ->
                val failure = shieldApplyFailure { if (policy == 1) awaitCancellation() }
                if (failure == null) completed += policy
            }
        }
        runCurrent(); policies.emit(1); runCurrent(); policies.emit(2); runCurrent()
        assertEquals(listOf(2), completed)
        collecting.cancelAndJoin()
    }
}

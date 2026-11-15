package dev.yab.sync

import dev.yab.agent.AgentProvider
import dev.yab.agent.RemoteConnection
import dev.yab.agent.RemoteMac
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SyncAwaitTest {
    @Test fun lostTransportCallbackEndsAtDeadlineAndLateCompletionHasNoEffect() = runTest {
        var callback: ((Result<Boolean>) -> Unit)? = null
        var finished = false
        val job = launch {
            try { awaitSyncCallback<Boolean>(1000) { callback = it }; fail("A missing callback cannot succeed") }
            catch (expected: TimeoutCancellationException) { finished = true }
        }
        runCurrent(); assertFalse(finished)
        advanceTimeBy(1000); runCurrent(); assertTrue(finished); assertTrue(job.isCompleted)
        callback!!(Result.success(true)); callback!!(Result.failure(IllegalStateException("late")))
        assertTrue(job.isCompleted)
    }
    @Test fun eligibleExplicitMacWinsAndAnIneligibleChoiceFallsBackLikeIosMacPick() {
        val first = RemoteMac("first", "First Mac", true, setOf(AgentProvider.CLAUDE))
        val second = RemoteMac("second", "Second Mac", true, setOf(AgentProvider.CLAUDE))
        val selected = RemoteConnection("account", listOf(first, second), selectedMac = first.id)
        assertEquals(second, selected.commandMac(listOf(second)))
        assertEquals(first, selected.commandMac(listOf(first, second)))
        assertEquals(first, selected.copy(selectedMac = null).commandMac(listOf(first, second)))
        assertEquals(second, selected.copy(selectedMac = null).commandMac(listOf(second)))
    }
}

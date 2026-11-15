package dev.yab.browser.engine

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class OwnedPageReadTest {
    @Test fun nativeLoadMayFinishBeforeTheSameDocumentConnects(): Unit = runTest {
        val channel = Any()
        var port: Any? = null
        val stages = mutableListOf<PageReadStage>()
        var requested: Any? = null
        val answer = async { readOwnedPage({ true }, { port }, { requested = it; delay(100); "body" }, { stages.add(it); Unit }) }
        runCurrent()
        assertNull(requested)
        advanceTimeBy(64); port = channel; advanceUntilIdle()
        assertEquals("body", answer.await()); assertSame(channel, requested)
        assertEquals(listOf(PageReadStage.WAITING_BRIDGE, PageReadStage.REQUEST_SENT, PageReadStage.RECEIVED), stages)
    }

    @Test fun navigationOrPrivateRevocationBeforeConnectionNeverSendsTheRequest(): Unit = runTest {
        var current = true
        var sends = 0
        val stages = mutableListOf<PageReadStage>()
        val answer = async { runCatching { readOwnedPage({ current }, { null as Any? }, { sends++; "body" }, { stages.add(it); Unit }) } }
        runCurrent(); current = false; advanceUntilIdle()
        assertTrue(answer.await().isFailure); assertEquals(0, sends)
        assertEquals(PageReadStage.OWNER_REVOKED, stages.last())
    }

    @Test fun aResponseFromAReplacedDocumentIsNeverReturned(): Unit = runTest {
        var current = true
        val response = CompletableDeferred<String>()
        val stages = mutableListOf<PageReadStage>()
        val answer = async { runCatching { readOwnedPage({ current }, { Any() }, { response.await() }, { stages.add(it); Unit }) } }
        runCurrent(); current = false; response.complete("retired body"); advanceUntilIdle()
        assertTrue(answer.await().isFailure)
        assertEquals(PageReadStage.OWNER_REVOKED, stages.last())
    }

    @Test fun connectionAndReplyShareTheOriginalThreeSecondBudget(): Unit = runTest {
        var port: Any? = null
        val response = CompletableDeferred<String>()
        val stages = mutableListOf<PageReadStage>()
        val answer = async { runCatching { readOwnedPage({ true }, { port }, { response.await() }, { stages.add(it); Unit }) } }
        runCurrent(); advanceTimeBy(2_900); port = Any(); advanceUntilIdle()
        assertTrue(answer.await().isFailure)
        assertEquals(3_000L, testScheduler.currentTime)
        assertEquals(PageReadStage.TIMED_OUT, stages.last())
    }

    @Test fun callerCancellationCannotBecomeARetryOrASuccess(): Unit = runTest {
        val stages = mutableListOf<PageReadStage>()
        var sends = 0
        val answer = async { readOwnedPage({ true }, { null as Any? }, { sends++; "body" }, { stages.add(it); Unit }) }
        runCurrent(); answer.cancel(); advanceUntilIdle()
        assertTrue(answer.isCancelled); assertEquals(0, sends)
        assertEquals(PageReadStage.CANCELLED, stages.last())
    }
}

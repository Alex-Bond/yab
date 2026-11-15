package dev.yab.browser

import dev.yab.browser.field.*
import java.time.Duration
import java.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class FieldRatesTest {
    @Test fun oneFixedRateRequestServesChangingWordsAndStaysFreshForThreeHours() = runTest {
        var now = Instant.parse("2026-10-23T12:00:00Z")
        val gate = CompletableDeferred<Map<String, Double>?>(); var requests = 0; var persisted: FieldRatesSnapshot? = null
        val rates = FieldRatesController(backgroundScope, now = { now }, persist = { persisted = it }) { requests++; gate.await() }
        rates.warm(); rates.warm(); runCurrent(); assertEquals(1, requests)
        gate.complete(mapOf("EUR" to 0.9, "GBP" to 0.8)); runCurrent()
        assertEquals("90", FieldCalculator.answer("100 dollars to euros", now, rates.state.value)?.copy)
        assertEquals("40", FieldCalculator.answer("50 dollars to pounds", now, rates.state.value)?.copy)
        assertEquals(rates.state.value, persisted)
        now = now.plus(Duration.ofHours(2)); rates.warm(); runCurrent(); assertEquals(1, requests)
        now = now.plus(Duration.ofHours(2)); rates.warm(); runCurrent(); assertEquals(2, requests)
    }

    @Test fun failureBackoffDoesNotInventRatesOrDiscardAnAvailableStaleAnswer() = runTest {
        var now = Instant.parse("2026-10-23T12:00:00Z"); var requests = 0
        val rates = FieldRatesController(backgroundScope, now = { now }) { requests++; null }
        rates.warm(); runCurrent(); assertTrue(rates.state.value.failed)
        assertEquals("", FieldCalculator.answer("100 dollars to euros", now, rates.state.value)?.copy)
        rates.warm(); runCurrent(); assertEquals(1, requests)
        now = now.plusSeconds(60); rates.warm(); runCurrent(); assertEquals(2, requests)
        assertEquals(now.plusSeconds(120), rates.state.value.retryAt)
        val stale = FieldRatesController(backgroundScope, now = { now }, initial = FieldRatesSnapshot(mapOf("EUR" to 0.9), now.minus(Duration.ofHours(8)))) { null }
        stale.warm(); runCurrent()
        assertFalse(stale.state.value.failed)
        assertEquals("90", FieldCalculator.answer("100 dollars to euros", now, stale.state.value)?.copy)
        assertTrue(requireNotNull(FieldCalculator.answer("100 dollars to euros", now, stale.state.value)).resultNote.endsWith(" · 8h ago"))
    }

    @Test fun malformedNegativeAndUnboundedRatesNeverBecomeAnAnswer() {
        assertNull(FieldRatesController.parse("{}"))
        assertNull(FieldRatesController.parse("x".repeat(512 * 1024 + 1)))
        val parsed = requireNotNull(FieldRatesController.parse("""{"data":{"rates":{"EUR":"0.9","GBP":"NaN","JPY":"-1","BTC":"Infinity","typed words":"4"}}}"""))
        assertEquals(mapOf("EUR" to 0.9), parsed)
    }
}

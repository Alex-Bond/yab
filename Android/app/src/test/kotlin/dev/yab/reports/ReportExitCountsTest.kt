package dev.yab.reports

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.*
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** New policy/API tests are an explicit AFTER-only overlay for the132 comparison. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ReportExitCountsTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val noon = 1_761_393_600_000L
    private val day = 86_400_000L
    private val metadata = ReportMetadata("1", "1", "Android", "Fixture", "dev.yab.android")
    private fun observation(n: Int, at: Long = noon, reason: Int = 5) = checkNotNull(
        ReportExitCounts.observation(at, 100 + n, reason, 100, "dev.yab.android:owned"))
    private fun crash(key: String) = SavedCrash(key, "1", "1", "Android", "Fixture", "dev.yab.Failure", listOf("dev.yab.Report.run:1"), noon)
    private fun body(request: ReportRequest) = json.parseToJsonElement(request.fields["report"]!!.jsonPrimitive.content.substringAfter('\n')).jsonObject
    private fun counts(request: ReportRequest) = body(request)["observedExitCounts"]!!.jsonObject["days"]!!.jsonArray
    private class Store(initial: ReportSnapshot = ReportSnapshot(since = 1, dailyActivity = false)) : ReportStore {
        private val json = Json { ignoreUnknownKeys = true }
        var checkpoint = json.encodeToString(initial)
        var failNextSave = false
        val saved: ReportSnapshot get() = json.decodeFromString(checkpoint)
        override suspend fun load(): ReportSnapshot = saved
        override suspend fun save(snapshot: ReportSnapshot) {
            if (failNextSave) { failNextSave = false; error("controlled storage refusal") }
            checkpoint = json.encodeToString(snapshot)
        }
    }

    @Test fun utcDaysSinceFutureAndSevenDayWindowAreExact() {
        val since = noon - 10 * day
        val today = ReportWire.day(noon)
        val edge = java.time.LocalDate.parse(today).atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli()
        val observations = listOf(observation(1, edge - 6 * day), observation(2, edge - 6 * day - 1),
            observation(3, edge - 1), observation(4, edge), observation(5, noon + 1), observation(6, since - 1))
        val ledger = ReportExitCounts.add(ReportExitLedger(), observations, since, noon)
        assertEquals(listOf(observations[0].id, observations[2].id, observations[3].id), ledger.pending.map { it.id })
        assertEquals(listOf(ReportWire.day(edge - 6 * day), ReportWire.day(edge - 1), today), ledger.pending.map { it.day })
        assertTrue(ReportExitCounts.add(ReportExitLedger(), listOf(observation(7, noon - 1)), noon, noon).pending.isEmpty())
    }

    @Test fun strictEnumsKeysDatesAndWireNeverExposeOsIdentityOrExactTime() {
        assertNull(ReportExitCounts.observation(noon, 1, -1, 100, "owned"))
        assertNull(ReportExitCounts.observation(noon, 1, 17, 100, "owned"))
        assertNull(ReportExitCounts.observation(noon, 1, 5, 999, "owned"))
        assertNull(ReportExitCounts.observation(noon, 0, 5, 100, "owned"))
        val original = observation(1)
        val bad = listOf(original.copy(id = "private.example"), original.copy(reason = 999), original.copy(importance = -1))
        assertTrue(ReportExitCounts.add(ReportExitLedger(), bad, 1, noon).pending.isEmpty())
        val ledger = ReportExitCounts.add(ReportExitLedger(), listOf(original), 1, noon)
        val invalid = ledger.copy(pending = ledger.pending + ledger.pending.single().copy(id = "b".repeat(64), day = "2025-02-29"))
        assertEquals(ledger, ReportExitCounts.prune(invalid, 1, noon))
        val wire = ReportExitCounts.wire(ledger.pending)!!.toString()
        for (word in listOf(original.id, noon.toString(), "owned", "pid", "process", "timestamp", "hangTime", "build")) assertFalse(word, wire.contains(word))
        val row = ReportExitCounts.wire(ledger.pending)!!["days"]!!.jsonArray.single().jsonObject["counts"]!!.jsonArray.single().jsonObject
        assertEquals(setOf("reason", "importance", "count"), row.keys)
        assertEquals(5, row["reason"]!!.jsonPrimitive.int); assertEquals(100, row["importance"]!!.jsonPrimitive.int)
    }

    @Test fun boundedContributionsAndTombstonesSurviveAckAndCannotBeReimported() {
        val input = (1..220).map { observation(it) }
        val ledger = input.chunked(10).fold(ReportExitLedger()) { ledger, batch -> ReportExitCounts.add(ledger, batch, 1, noon) }
        assertEquals(200, ledger.pending.size); assertEquals(200, ledger.seen.size)
        assertEquals(input.takeLast(200).map { it.id }, ledger.pending.map { it.id })
        val captured = ledger.pending.takeLast(10).map { it.id }.toSet()
        val ack = ReportExitCounts.acknowledge(ledger, captured)
        assertEquals(190, ack.pending.size); assertEquals(ledger.seen, ack.seen)
        assertEquals(ack, ReportExitCounts.add(ack, input.takeLast(10), 1, noon))
        assertTrue(ReportExitCounts.wire(ledger.pending)!!.toString().toByteArray().size < ReportExitCounts.MAX_WIRE_BYTES)
        val longFrame = "dev.yab." + "X".repeat(220)
        val report = ReportWire.reportText(crash("large").copy(frames = List(512) { longFrame }), ledger.pending)
        assertTrue(report.toByteArray().size < 256 * 1024)
    }

    @Test fun loadedPendingWithoutSeenIsRepairedBeforeAckAndCannotReenter() {
        val input = observation(1)
        val original = ReportExitCounts.add(ReportExitLedger(), listOf(input), 1, noon).copy(seen = emptyList())
        val restored = ReportExitCounts.prune(original, 1, noon)
        assertEquals(listOf(input.id), restored.seen)
        val acknowledged = ReportExitCounts.acknowledge(restored, setOf(input.id))
        assertEquals(acknowledged, ReportExitCounts.add(acknowledged, listOf(input), 1, noon))
    }

    @Test fun initializationAndActiveTickDurablyExpireCountsAndAllowedIdsWithoutPosting(): Unit = runTest {
        var clock = noon
        val old = observation(1, noon - 8 * day); val current = observation(2, noon - 6 * day)
        val all = ReportExitLedger(listOf(
            ReportExitContribution(old.id, ReportWire.day(old.at), old.reason, old.importance),
            ReportExitContribution(current.id, ReportWire.day(current.at), current.reason, current.importance)),
            setOf(old.id, current.id), listOf(old.id, current.id))
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false, exitCounts = all))
        val posted = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posted.add(it); true }, metadata, backgroundScope, now = { clock })
        try {
            runCurrent()
            assertEquals(listOf(current.id), store.saved.exitCounts.pending.map { it.id })
            assertEquals(setOf(current.id), store.saved.exitCounts.allowed)
            controller.foregrounded(true); runCurrent(); clock += 7 * day; controller.tick(); runCurrent()
            assertTrue(store.saved.exitCounts.pending.isEmpty()); assertTrue(store.saved.exitCounts.allowed.isEmpty())
            assertNull(ReportExitCounts.wire(store.saved.exitCounts.pending)); assertTrue(posted.isEmpty())
        } finally { controller.close() }
    }

    @Test fun failedDurableExpiryRefusesFurtherCaptureOrPost(): Unit = runTest {
        var clock = noon
        val input = observation(1)
        val ledger = ReportExitCounts.allow(ReportExitCounts.add(ReportExitLedger(), listOf(input), 1, noon), setOf(input.id))
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false, exitCounts = ledger))
        val controller = ReportsController(store, ReportTransport { error("Failed expiry must not post") }, metadata, backgroundScope, now = { clock })
        try {
            runCurrent(); controller.foregrounded(true); runCurrent()
            clock += 7 * day; store.failNextSave = true; controller.tick(); runCurrent()
            assertFalse(controller.state.value.available); assertNotNull(controller.state.value.storageError)
            assertEquals(listOf(input.id), store.saved.exitCounts.pending.map { it.id })
            assertFalse(controller.received(listOf(crash("refused")), listOf(observation(2, clock))))
        } finally { controller.close() }
    }

    @Test fun countsAloneNeverAskOrPostEvenWithAutomaticSending(): Unit = runTest {
        for (automatic in listOf(false, true)) {
            val store = Store(ReportSnapshot(since = 1, dailyActivity = false, automaticCrashes = automatic))
            val posted = mutableListOf<ReportRequest>()
            val controller = ReportsController(store, ReportTransport { posted.add(it); true }, metadata, backgroundScope, now = { noon })
            try {
                runCurrent(); controller.foregrounded(true)
                assertTrue(controller.received(emptyList(), listOf(observation(1)))); runCurrent()
                assertNull(controller.state.value.question); assertTrue(posted.isEmpty())
                assertEquals(1, store.saved.exitCounts.pending.size)
            } finally { controller.close() }
        }
    }

    @Test fun manualQuestionCannotGrantLaterCountsOrBorrowThemOnAnApprovedRetry(): Unit = runTest {
        val store = Store(); val posted = mutableListOf<ReportRequest>()
        val a = observation(1); val b = observation(2, reason = 6)
        val controller = ReportsController(store, ReportTransport { posted.add(it); false }, metadata, backgroundScope, now = { noon })
        try {
            runCurrent(); controller.foregrounded(true)
            controller.received(listOf(crash("c1")), listOf(a)); runCurrent()
            val question = requireNotNull(controller.state.value.question)
            assertEquals(setOf(a.id), question.exitKeys)
            controller.received(listOf(crash("c2")), listOf(b)); runCurrent()
            assertEquals(question, controller.state.value.question)
            controller.answer(question.token, true); runCurrent()
            assertEquals(setOf(a.id), store.saved.exitCounts.allowed)
            assertTrue(posted.isNotEmpty())
            posted.forEach { assertEquals(5, counts(it).single().jsonObject["counts"]!!.jsonArray.single().jsonObject["reason"]!!.jsonPrimitive.int) }
            assertEquals(setOf(b.id), controller.state.value.question!!.exitKeys)
        } finally { controller.close() }
    }

    @Test fun oldAllowedReportCannotAcquireNewUnapprovedCounts(): Unit = runTest {
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false, pending = listOf(crash("old")), allowed = setOf("old")))
        val posted = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posted.add(it); true }, metadata, backgroundScope, now = { noon })
        try {
            runCurrent(); controller.received(emptyList(), listOf(observation(1))); controller.foregrounded(true); runCurrent()
            assertEquals(1, posted.size); assertFalse(body(posted.single()).containsKey("observedExitCounts"))
            assertEquals(1, store.saved.exitCounts.pending.size); assertTrue(store.saved.exitCounts.allowed.isEmpty())
        } finally { controller.close() }
    }

    @Test fun heldSuccessfulAckPreservesLateContributionOnTheSameDay(): Unit = runTest {
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false, automaticCrashes = true))
        val release = CompletableDeferred<Boolean>(); val posted = mutableListOf<ReportRequest>()
        val a = observation(1); val b = observation(2)
        val controller = ReportsController(store, ReportTransport { posted.add(it); if (posted.size == 1) release.await() else true }, metadata, backgroundScope, now = { noon })
        try {
            runCurrent(); controller.received(listOf(crash("c1")), listOf(a)); controller.foregrounded(true); runCurrent()
            assertEquals(1, posted.size)
            controller.received(emptyList(), listOf(b)); runCurrent()
            release.complete(true); runCurrent()
            assertEquals(listOf(b.id), store.saved.exitCounts.pending.map { it.id })
            assertEquals(setOf(a.id, b.id), store.saved.exitCounts.seen.toSet())
            controller.received(listOf(crash("c2"))); runCurrent()
            assertEquals(2, posted.size); assertTrue(store.saved.exitCounts.pending.isEmpty())
            posted.forEach { assertEquals(1, counts(it).single().jsonObject["counts"]!!.jsonArray.single().jsonObject["count"]!!.jsonPrimitive.int) }
        } finally { controller.close(); release.cancel() }
    }

    @Test fun declineOnlyDropsOriginalUnapprovedCountsAndStaleAnswerCannotGrantTheSuccessor(): Unit = runTest {
        val a = observation(1); val b = observation(2); val c = observation(3)
        val original = ReportExitCounts.allow(ReportExitCounts.add(ReportExitLedger(), listOf(a, b), 1, noon), setOf(a.id))
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false, exitCounts = original))
        val controller = ReportsController(store, ReportTransport { error("No report was approved") }, metadata, backgroundScope, now = { noon })
        try {
            runCurrent(); controller.received(listOf(crash("c1"))); controller.foregrounded(true); runCurrent()
            val question = requireNotNull(controller.state.value.question); assertEquals(setOf(b.id), question.exitKeys)
            controller.received(emptyList(), listOf(c)); controller.answer(question.token, false); runCurrent()
            assertEquals(listOf(a.id, c.id), store.saved.exitCounts.pending.map { it.id })
            assertEquals(setOf(a.id), store.saved.exitCounts.allowed)
            controller.received(listOf(crash("c2"))); runCurrent()
            val fresh = requireNotNull(controller.state.value.question)
            controller.backgrounded(); controller.answer(fresh.token, true); runCurrent()
            assertEquals(setOf(a.id), store.saved.exitCounts.allowed)
            controller.foregrounded(true); runCurrent(); controller.answer(fresh.token, true); runCurrent()
            assertNotEquals(fresh.token, controller.state.value.question!!.token)
            assertEquals(setOf(a.id), store.saved.exitCounts.allowed)
        } finally { controller.close() }
    }

    @Test fun failedAckStoreKeepsOriginalGrantAndContributionForRelaunch(): Unit = runTest {
        val a = observation(1)
        val ledger = ReportExitCounts.allow(ReportExitCounts.add(ReportExitLedger(), listOf(a), 1, noon), setOf(a.id))
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false, pending = listOf(crash("c1")), allowed = setOf("c1"), exitCounts = ledger))
        val posted = mutableListOf<ReportRequest>()
        val first = ReportsController(store, ReportTransport { posted.add(it); store.failNextSave = true; true }, metadata, backgroundScope, now = { noon })
        try {
            runCurrent(); first.foregrounded(true); runCurrent()
            assertFalse(first.state.value.available); assertEquals(ledger, store.saved.exitCounts)
            assertEquals(listOf("c1"), store.saved.pending.map { it.key }); first.close()
            val next = ReportsController(store, ReportTransport { posted.add(it); true }, metadata, backgroundScope, now = { noon })
            try {
                runCurrent(); next.foregrounded(true); runCurrent()
                assertEquals(2, posted.size); assertEquals(counts(posted.first()), counts(posted.last()))
                assertTrue(store.saved.pending.isEmpty()); assertTrue(store.saved.exitCounts.pending.isEmpty())
                assertEquals(listOf(a.id), store.saved.exitCounts.seen)
            } finally { next.close() }
        } finally { first.close() }
    }

    @Test fun thrownPostRetainsGrantAndStorageRefusalCannotPublishObservations(): Unit = runTest {
        val a = observation(1); val store = Store()
        val controller = ReportsController(store, ReportTransport { error("controlled refusal") }, metadata, backgroundScope, now = { noon })
        try {
            runCurrent(); controller.received(listOf(crash("c1")), listOf(a)); controller.foregrounded(true); runCurrent()
            controller.answer(controller.state.value.question!!.token, true); runCurrent()
            assertEquals(setOf(a.id), store.saved.exitCounts.allowed); assertEquals(1, store.saved.pending.size)
            store.failNextSave = true
            assertFalse(controller.received(emptyList(), listOf(observation(2))))
            assertEquals(listOf(a.id), store.saved.exitCounts.pending.map { it.id }); assertFalse(controller.state.value.available)
        } finally { controller.close() }
    }

    @Test fun absentSiteAndFirstEligibleBacklogNeverGrantHistoricalObservations(): Unit = runTest {
        val noSiteStore = Store(); val noSite = ReportsController(noSiteStore, null, metadata, backgroundScope, now = { noon })
        try {
            runCurrent(); assertFalse(noSite.received(emptyList(), listOf(observation(1))))
            assertTrue(noSiteStore.saved.exitCounts.pending.isEmpty())
        } finally { noSite.close() }
        var clock = noon
        val store = Store(ReportSnapshot(dailyActivity = false)); val posted = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posted.add(it); true }, metadata, backgroundScope, now = { clock })
        try {
            runCurrent(); clock += 100
            controller.received(listOf(crash("old-backlog")), listOf(observation(1, noon - 1), observation(2, clock)))
            controller.foregrounded(true); runCurrent()
            assertNull(controller.state.value.question); assertTrue(posted.isEmpty()); assertTrue(store.saved.pending.isEmpty())
            assertEquals(listOf(observation(2, clock).id), store.saved.exitCounts.pending.map { it.id })
            assertTrue(store.saved.exitCounts.allowed.isEmpty())
        } finally { controller.close() }
    }

    @Test fun heldAckKeepsPendingIdentityDespiteAFullDeclinedTombstoneWindow(): Unit = runTest {
        val original = (1..200).map { observation(it) }
        val a = original.first(); val b = observation(201)
        val full = original.chunked(10).fold(ReportExitLedger()) { ledger, batch ->
            ReportExitCounts.add(ledger, batch, 1, noon)
        }
        val allowed = ReportExitCounts.allow(full, setOf(a.id))
        val declined = ReportExitCounts.decline(allowed, original.drop(1).map { it.id }.toSet())
        assertEquals(listOf(a.id), declined.pending.map { it.id })
        assertEquals(200, declined.seen.size); assertEquals(a.id, declined.seen.first())
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false,
            pending = listOf(crash("held")), allowed = setOf("held"), exitCounts = declined))
        val release = CompletableDeferred<Boolean>(); val posted = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posted.add(it); release.await() }, metadata, backgroundScope, now = { noon })
        try {
            runCurrent(); controller.foregrounded(true); runCurrent()
            assertEquals(1, posted.size)
            assertTrue(controller.received(emptyList(), listOf(b))); runCurrent()
            release.complete(true); runCurrent()
            val aWasSeenAfterItsAck = a.id in store.saved.exitCounts.seen
            assertTrue(controller.received(emptyList(), listOf(a))); runCurrent()
            assertTrue("The same original observation must not reenter after its held ACK",
                store.saved.exitCounts.pending.map { it.id } == listOf(b.id))
            assertTrue("Every pending original identity must survive the bounded seen window and its ACK", aWasSeenAfterItsAck)
            assertEquals(1, posted.size); assertNull(controller.state.value.question)
            assertEquals(setOf(a.id, b.id).intersect(store.saved.exitCounts.seen.toSet()), setOf(a.id, b.id))
        } finally { controller.close(); release.cancel() }
    }
}

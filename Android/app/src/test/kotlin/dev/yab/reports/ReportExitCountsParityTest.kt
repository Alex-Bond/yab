package dev.yab.reports

import kotlinx.coroutines.test.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Opaque checkpoints and original APIs compile on exact132 as well as133. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ReportExitCountsParityTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val now = 1_761_350_400_000L // 2025-10-25 UTC; fixture-only numeric metadata.
    private val id = "a".repeat(64)
    private val metadata = ReportMetadata("1", "1", "Android", "Fixture", "dev.yab.android")
    private class Store(var checkpoint: String) : ReportStore {
        private val json = Json { ignoreUnknownKeys = true }
        override suspend fun load(): ReportSnapshot = json.decodeFromString(checkpoint)
        override suspend fun save(snapshot: ReportSnapshot) { checkpoint = json.encodeToString(snapshot) }
    }
    private fun fixture(approved: Boolean, two: Boolean = false): String {
        val keys = if (two) listOf("c1", "c2") else listOf("c1")
        return buildJsonObject {
            put("since", 1); put("dailyActivity", false)
            put("pending", buildJsonArray { keys.forEach { key -> add(buildJsonObject {
                put("key", key); put("version", "1"); put("build", "1"); put("os", "Android")
                put("device", "Fixture"); put("reason", "dev.yab.Failure"); put("at", now)
                put("frames", buildJsonArray { add("dev.yab.Report.run:1") })
            }) } })
            put("allowed", buildJsonArray { if (approved) keys.forEach { add(it) } })
            put("seen", buildJsonArray { keys.forEach { add(it) } })
            put("exitCounts", buildJsonObject {
                put("pending", buildJsonArray { add(buildJsonObject {
                    put("id", id); put("day", ReportWire.day(now)); put("reason", 5); put("importance", 100)
                }) })
                put("allowed", buildJsonArray { if (approved) add(id) })
                put("seen", buildJsonArray { add(id) })
            })
        }.toString()
    }
    private fun body(request: ReportRequest) = json.parseToJsonElement(request.fields["report"]!!.jsonPrimitive.content.substringAfter('\n')).jsonObject

    @Test fun approvedObservedCountsUseVersionedBodyOnlyOnFirstReport(): Unit = runTest {
        val store = Store(fixture(approved = true, two = true)); val posted = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posted.add(it); true }, metadata, backgroundScope, now = { now })
        try {
            runCurrent(); controller.foregrounded(true); runCurrent()
            assertEquals(2, posted.size)
            val counts = body(posted.first())["observedExitCounts"]
            assertNotNull("The approved original observation belongs inside the first report body", counts)
            assertEquals(1, counts!!.jsonObject["version"]!!.jsonPrimitive.int)
            assertEquals("observed", counts.jsonObject["coverage"]!!.jsonPrimitive.content)
            assertEquals(10, counts.jsonObject["maxRecordsPerImport"]!!.jsonPrimitive.int)
            assertFalse(posted.first().fields.containsKey("exits")); assertFalse(posted.first().fields.containsKey("observedExitCounts"))
            assertFalse(body(posted.last()).containsKey("observedExitCounts"))
        } finally { controller.close() }
    }

    @Test fun refusedTransportKeepsApprovedCountsAndRetryUsesTheSameContribution(): Unit = runTest {
        val store = Store(fixture(approved = true)); val posted = mutableListOf<ReportRequest>()
        val first = ReportsController(store, ReportTransport { posted.add(it); false }, metadata, backgroundScope, now = { now })
        try {
            runCurrent(); first.foregrounded(true); runCurrent()
            assertEquals(1, posted.size)
            assertNotNull("Refused posts must still carry the original approved counts", body(posted.single())["observedExitCounts"])
            val captured = body(posted.single())["observedExitCounts"]
            first.close()
            val next = ReportsController(store, ReportTransport { posted.add(it); true }, metadata, backgroundScope, now = { now })
            try {
                runCurrent(); next.foregrounded(true); runCurrent()
                assertNull(next.state.value.question); assertEquals(2, posted.size)
                assertEquals(captured, body(posted.last())["observedExitCounts"])
                val state = json.parseToJsonElement(store.checkpoint).jsonObject
                assertTrue(state["pending"]?.jsonArray.orEmpty().isEmpty())
                val ledger = state["exitCounts"]!!.jsonObject
                assertTrue(ledger["pending"]?.jsonArray.orEmpty().isEmpty())
                assertEquals(listOf(id), ledger["seen"]!!.jsonArray.map { it.jsonPrimitive.content })
            } finally { next.close() }
        } finally { first.close() }
    }

    @Test fun declineRetiresOnlyCapturedCountsAndKeepsTheirSeenIdentity(): Unit = runTest {
        val store = Store(fixture(approved = false)); val posted = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posted.add(it); true }, metadata, backgroundScope, now = { now })
        try {
            runCurrent(); controller.foregrounded(true); runCurrent()
            val question = requireNotNull(controller.state.value.question)
            controller.answer(question.token, false); runCurrent()
            assertTrue(posted.isEmpty()); assertFalse(controller.state.value.automaticCrashes)
            val ledger = json.parseToJsonElement(store.checkpoint).jsonObject["exitCounts"]
            assertNotNull("Decline preserves a tombstone for each captured observation", ledger)
            assertTrue(ledger!!.jsonObject["pending"]?.jsonArray.orEmpty().isEmpty())
            assertEquals(listOf(id), ledger.jsonObject["seen"]!!.jsonArray.map { it.jsonPrimitive.content })
        } finally { controller.close() }
    }

    @Test fun absentCountsKeepLegacySnapshotAndRequestShape() {
        val snapshot = json.decodeFromString<ReportSnapshot>("""{"since":1,"dailyActivity":false}""")
        assertFalse(json.parseToJsonElement(json.encodeToString(snapshot)).jsonObject.containsKey("exitCounts"))
        val crash = SavedCrash("c", "1", "1", "Android", "Fixture", "dev.yab.Failure", listOf("dev.yab.Report.run:1"), now)
        assertFalse(body(ReportWire.crash(crash)).containsKey("observedExitCounts"))
        assertEquals(ReportWire.reportText(crash).toByteArray().size, ReportWire.crash(crash).fields["bytes"]!!.jsonPrimitive.int)
    }

    @Test fun closedControllerCannotAcknowledgeItsHeldPostIntoTheSuccessorsCheckpoint(): Unit = runTest {
        val store = Store(fixture(approved = true)); val release = CompletableDeferred<Boolean>()
        val first = ReportsController(store, ReportTransport { withContext(NonCancellable) { release.await() } }, metadata, backgroundScope, now = { now })
        var successor: ReportsController? = null
        try {
            runCurrent(); first.foregrounded(true); runCurrent(); first.close()
            // A fresh owner's legitimate restored checkpoint includes a later contribution.
            val state = json.parseToJsonElement(store.checkpoint).jsonObject.toMutableMap()
            val ledger = state.getValue("exitCounts").jsonObject.toMutableMap()
            val later = buildJsonObject {
                put("id", "b".repeat(64)); put("day", ReportWire.day(now)); put("reason", 6); put("importance", 100)
            }
            ledger["pending"] = JsonArray(ledger.getValue("pending").jsonArray + later)
            ledger["seen"] = JsonArray(ledger.getValue("seen").jsonArray + JsonPrimitive("b".repeat(64)))
            state["exitCounts"] = JsonObject(ledger); store.checkpoint = JsonObject(state).toString()
            val fresh = ReportsController(store, ReportTransport { error("Inactive successor must not post") }, metadata, backgroundScope, now = { now })
            successor = fresh; runCurrent()
            val laterReport = SavedCrash("later", "1", "1", "Android", "Fixture", "dev.yab.Failure", emptyList(), now)
            assertTrue(fresh.received(listOf(laterReport))); runCurrent()
            val current = store.checkpoint
            release.complete(true); runCurrent()
            assertEquals("A closed producer cannot overwrite the new owner's durable checkpoint", current, store.checkpoint)
            assertEquals(listOf("c1", "later"), store.load().pending.map { it.key })
        } finally { first.close(); successor?.close(); release.complete(false) }
    }

    @Test fun closedDailyActivityCannotOverwriteTheSuccessorsCheckpoint(): Unit = runTest {
        val initial = json.parseToJsonElement(fixture(approved = false)).jsonObject.toMutableMap()
        initial["dailyActivity"] = JsonPrimitive(true)
        initial["installation"] = JsonPrimitive("123e4567-e89b-42d3-a456-426614174000")
        val store = Store(JsonObject(initial).toString()); val release = CompletableDeferred<Boolean>()
        val first = ReportsController(store, ReportTransport {
            assertEquals("api/activity", it.path)
            withContext(NonCancellable) { release.await() }
        }, metadata, backgroundScope, now = { now })
        var successor: ReportsController? = null
        try {
            runCurrent(); first.foregrounded(false); runCurrent(); first.close()
            val state = json.parseToJsonElement(store.checkpoint).jsonObject.toMutableMap()
            val ledger = state.getValue("exitCounts").jsonObject.toMutableMap()
            val later = buildJsonObject {
                put("id", "b".repeat(64)); put("day", ReportWire.day(now)); put("reason", 6); put("importance", 100)
            }
            ledger["pending"] = JsonArray(ledger.getValue("pending").jsonArray + later)
            ledger["seen"] = JsonArray(ledger.getValue("seen").jsonArray + JsonPrimitive("b".repeat(64)))
            state["exitCounts"] = JsonObject(ledger); store.checkpoint = JsonObject(state).toString()
            val fresh = ReportsController(store, ReportTransport { error("Inactive successor must not post") }, metadata, backgroundScope, now = { now })
            successor = fresh; runCurrent()
            val laterReport = SavedCrash("later", "1", "1", "Android", "Fixture", "dev.yab.Failure", emptyList(), now)
            assertTrue(fresh.received(listOf(laterReport))); runCurrent()
            val current = store.checkpoint
            release.complete(true); runCurrent()
            assertEquals("A closed activity producer cannot overwrite the successor's durable checkpoint", current, store.checkpoint)
            assertNull(store.load().lastDay)
            assertEquals(listOf("c1", "later"), store.load().pending.map { it.key })
        } finally { first.close(); successor?.close(); release.complete(false) }
    }
}

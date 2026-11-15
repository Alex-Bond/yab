package dev.yab.core

import dev.yab.core.sync.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class TaskRecordsTest {
    private fun vectors(): JsonArray = Json.parseToJsonElement(javaClass.getResourceAsStream("/task-vectors-v1.json")!!.bufferedReader().use { it.readText() }).jsonObject.getValue("cases").jsonArray
    private fun request(): TaskRecords.Request = TaskRecords.Request.decode(Json.parseToJsonElement(vectors()[2].jsonObject.getValue("input").jsonPrimitive.content).jsonObject)
    private fun observation(request: TaskRecords.Request, revision: String, status: String = "running", text: String? = null): TaskRecords.Observation = TaskRecords.Observation.decode(buildJsonObject {
        put("version", 1); put("task", request.id); put("requestDigest", request.digest()); put("account", request.account); put("phone", request.phone); put("mac", request.mac)
        put("revision", Json.parseToJsonElement(revision)); put("session", "actual-session"); put("status", status); put("title", "Actual title"); put("progress", "Actual progress")
        text?.let { put("result", it) }
    }, request)
    @Test fun requestsAndObservedResultsMatchProductionSwiftModels() {
        for (item in vectors()) {
            val vector = item.jsonObject
            val request = TaskRecords.Request.decode(Json.parseToJsonElement(vector.getValue("input").jsonPrimitive.content).jsonObject)
            assertEquals(vector.getValue("canonical").jsonPrimitive.content, request.body())
            assertEquals(vector.getValue("digest").jsonPrimitive.content, request.digest())
            val observed = TaskRecords.Observation.decode(Json.parseToJsonElement(vector.getValue("observation").jsonPrimitive.content).jsonObject, request)
            assertEquals(vector.getValue("observation").jsonPrimitive.content, observed.body())
            assertEquals(4_294_967_296uL, observed.revision)
        }
    }
    @Test fun readerRequiresExactOwnedBodyAndObservationBoundToTheAuthoredRequest() {
        val request = request(); val clock = Clock(request.phone)
        val record = Record(TaskRecords.REQUEST, request.id).updated(request.fields(), clock)
        assertEquals(request, TaskRecords.Request.read(record, request.account, request.phone))
        assertThrows(IllegalArgumentException::class.java) { TaskRecords.Request.read(record, "other-account", request.phone) }
        assertThrows(IllegalArgumentException::class.java) { TaskRecords.Request.read(record.copy(stamps = mapOf("body" to Stamp(1, device = "another-phone"))), request.account, request.phone) }
        assertThrows(IllegalArgumentException::class.java) { TaskRecords.Request.read(record.copy(fields = JsonObject(record.fields + ("extra" to JsonPrimitive(true)))), request.account, request.phone) }
        assertThrows(IllegalArgumentException::class.java) { TaskRecords.Request.read(record.removed(Stamp(Long.MAX_VALUE, device = request.phone)), request.account, request.phone) }
        val observed = observation(request, "1")
        val owned = Record(TaskRecords.OBSERVATION, request.id).updated(observed.fields(), Clock(request.mac))
        assertEquals(observed, TaskRecords.Observation.read(owned, request))
        assertThrows(IllegalArgumentException::class.java) { TaskRecords.Observation.read(owned.copy(id = "another-task"), request) }
        val changedRequest = TaskRecords.Request.decode(JsonObject(request.facts + ("words" to JsonPrimitive("Changed after observation"))))
        assertThrows(IllegalArgumentException::class.java) { TaskRecords.Observation.read(owned, changedRequest) }
    }
    @Test fun producerEligibilityIsSeparateFromTransportAndCannotBorrowAnotherWriterEpoch() {
        val mac = "mac"; val clock = Clock(mac)
        val epoch = "00000000-0000-0000-0000-000000000023"
        val transport = Record("commandcap", mac).updated(buildJsonObject { put("device", mac); put("taskRecords", 1) }, clock)
        assertTrue(TaskRecords.supports(transport, mac)); assertNull(TaskRecords.readOnlyEpoch(transport, mac))
        val eligible = transport.updated(JsonObject(transport.visible + mapOf("taskReadOnly" to JsonPrimitive(1), "taskReadOnlyEpoch" to JsonPrimitive(epoch))), clock)
        assertEquals(epoch, TaskRecords.readOnlyEpoch(eligible, mac))
        assertNull(TaskRecords.readOnlyEpoch(eligible.copy(stamps = eligible.stamps + ("taskReadOnlyEpoch" to Stamp(1, device = "phone"))), mac))
        assertNull(TaskRecords.readOnlyEpoch(eligible.copy(schema = 2), mac))
    }
    @Test fun statusesCannotInventResultsAndUnsignedRevisionsDoNotOverflow() {
        val request = request()
        assertThrows(IllegalArgumentException::class.java) { observation(request, "1", "done") }
        assertThrows(IllegalArgumentException::class.java) { observation(request, "1", "needsYou", "Pretend payment result") }
        assertThrows(IllegalArgumentException::class.java) { observation(request, "0") }
        assertEquals(ULong.MAX_VALUE, observation(request, "18446744073709551615").revision)
        assertThrows(IllegalArgumentException::class.java) { TaskRecords.Request.decode(JsonObject(request.facts + ("url" to JsonPrimitive("javascript:alert(1)")))) }
    }
    @Test fun inboxRejectsRegressionsAndConflictingReplayAcrossIndependentInstancesAndRelaunch() {
        val directory = Files.createTempDirectory("task-inbox").toFile()
        try {
            val file = File(directory, "inbox.json"); val request = request()
            val first = TaskRecordInbox(file, request.account, request.phone)
            val replacement = TaskRecordInbox(file, request.account, request.phone)
            val running = observation(request, "1"); val done = observation(request, "2", "done", "Actual result")
            assertTrue(first.accept(running, request)); assertTrue(replacement.accept(done, request))
            assertFalse(first.accept(done, request))
            assertThrows(IllegalArgumentException::class.java) { first.accept(running, request) }
            assertThrows(IllegalArgumentException::class.java) { first.accept(observation(request, "2", "done", "Conflicting result"), request) }
            assertEquals(done, TaskRecordInbox(file, request.account, request.phone).current(request))
            assertThrows(IllegalArgumentException::class.java) { TaskRecordInbox(file, "another-account", request.phone) }
            file.writeText("{broken")
            assertThrows(Exception::class.java) { TaskRecordInbox(file, request.account, request.phone) }
        } finally { directory.deleteRecursively() }
    }
}

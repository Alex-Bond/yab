package dev.yab.browser

import dev.yab.reports.*
import dev.yab.core.sync.Record
import dev.yab.core.sync.Stamp
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ReportsConsentTest {
    private val metadata = ReportMetadata("0.1.0", "3", "Android 16 API 36", "Fixture", "dev.yab.android.dev")
    private val id = "3f1c2b4a-9d8e-4c7b-a6f5-0e1d2c3b4a59"
    private fun crash(key: String) = SavedCrash(key, "0.1.0", "3", "Android 16", "Fixture", "java.lang.IllegalStateException", listOf("dev.yab.Engine.load:82"), 20)
    private class Store(var saved: ReportSnapshot = ReportSnapshot(since = 1, dailyActivity = false)) : ReportStore {
        var fail = false
        override suspend fun load(): ReportSnapshot { check(!fail); return saved }
        override suspend fun save(snapshot: ReportSnapshot) { check(!fail); saved = snapshot }
    }

    @Test fun absentSiteAndStorageFailureCannotSendOrAcquireInstallationIdentity(): Unit = runTest {
        val noSite = Store(ReportSnapshot())
        val controller = ReportsController(noSite, null, metadata, backgroundScope)
        runCurrent(); controller.foregrounded(true); runCurrent()
        assertFalse(controller.state.value.available)
        assertNull(noSite.saved.installation)
        assertEquals(0, noSite.saved.since)
        assertFalse(controller.received(listOf(crash("not-collected"))))
        controller.close()
        val broken = Store().apply { fail = true }
        var posts = 0
        val guarded = ReportsController(broken, ReportTransport { posts++; true }, metadata, backgroundScope)
        runCurrent(); guarded.foregrounded(true); runCurrent()
        assertEquals(0, posts)
        assertNotNull(guarded.state.value.storageError)
        guarded.close()
    }

    @Test fun firstEligibleLaunchPassesBacklogWithoutAskingOrSending(): Unit = runTest {
        val store = Store(ReportSnapshot())
        val posts = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posts.add(it); true }, metadata, backgroundScope, now = { 100 })
        runCurrent()
        controller.received(listOf(crash("old")))
        controller.foregrounded(true); runCurrent()
        assertEquals(listOf("old"), store.saved.seen)
        assertTrue(store.saved.pending.isEmpty())
        assertNull(controller.state.value.question)
        assertTrue(posts.none { it.path == "api/crash" })
        controller.close()
    }

    @Test fun declineCoversOnlyTheShownSetAndLaterCrashesAskAgain(): Unit = runTest {
        val store = Store()
        val requests = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { requests.add(it); true }, metadata, backgroundScope)
        runCurrent(); controller.foregrounded(false)
        controller.received(listOf(crash("a"))); runCurrent()
        assertNull(controller.state.value.question)
        controller.setPresentationAllowed(true); runCurrent()
        val first = controller.state.value.question!!
        controller.received(listOf(crash("b"))); runCurrent()
        controller.answer(first.token, false); runCurrent()
        assertEquals(listOf("b"), store.saved.pending.map { it.key })
        assertEquals(setOf("b"), controller.state.value.question!!.keys)
        assertFalse(store.saved.automaticCrashes)
        assertTrue(requests.isEmpty())
        controller.received(listOf(crash("a"))); runCurrent()
        assertEquals(listOf("b"), store.saved.pending.map { it.key })
        controller.close()
    }

    @Test fun approvedFailedSendSurvivesRelaunchWithoutAskingAgain(): Unit = runTest {
        val store = Store()
        val first = ReportsController(store, ReportTransport { false }, metadata, backgroundScope)
        runCurrent(); first.received(listOf(crash("approved"))); first.foregrounded(true); runCurrent()
        first.answer(first.state.value.question!!.token, true); runCurrent()
        assertEquals(setOf("approved"), store.saved.allowed)
        assertFalse(store.saved.automaticCrashes)
        first.close()
        val sent = mutableListOf<ReportRequest>()
        val next = ReportsController(store, ReportTransport { sent.add(it); true }, metadata, backgroundScope)
        runCurrent(); next.foregrounded(true); runCurrent()
        assertNull(next.state.value.question)
        assertEquals(listOf("api/crash"), sent.map { it.path })
        assertTrue(store.saved.pending.isEmpty())
        next.close()
    }

    @Test fun dailyActivityCountsOnlyAcceptedUtcDaysAndContainsNoBrowserFields(): Unit = runTest {
        val store = Store(ReportSnapshot(since = 1, installation = id, person = id))
        var time = 86_399_000L
        var accepted = false
        val requests = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { requests.add(it); accepted }, metadata, backgroundScope, now = { time })
        runCurrent(); controller.foregrounded(true); runCurrent()
        assertNull(store.saved.lastDay)
        accepted = true; controller.tick(); runCurrent()
        assertEquals("1970-01-01", store.saved.lastDay)
        controller.tick(); runCurrent(); assertEquals(2, requests.size)
        time = 86_400_000L; controller.tick(); runCurrent()
        assertEquals("1970-01-02", store.saved.lastDay)
        assertEquals(setOf("id", "person", "platform"), requests.last().fields.keys)
        assertEquals("android", requests.last().fields["platform"]!!.jsonPrimitive.content)
        controller.dailyActivity(false); runCurrent()
        time += 86_400_000L; controller.tick(); runCurrent(); assertEquals(3, requests.size)
        controller.close()
    }

    @Test fun simultaneousRefreshDoesNotDuplicateAnInFlightDailyRequest(): Unit = runTest {
        val store = Store(ReportSnapshot(since = 1, installation = id))
        val result = CompletableDeferred<Boolean>()
        var calls = 0
        val controller = ReportsController(store, ReportTransport { calls++; result.await() }, metadata, backgroundScope, now = { 200 })
        runCurrent(); controller.foregrounded(true); runCurrent()
        repeat(10) { controller.tick() }; runCurrent()
        assertEquals(1, calls)
        result.complete(true); runCurrent(); controller.tick(); runCurrent()
        assertEquals(1, calls)
        controller.close()
    }

    @Test fun openingConsentWhileDailyTransportIsSuspendedCannotLoseTheQuestion(): Unit = runTest {
        val store = Store(ReportSnapshot(since = 1, installation = id, pending = listOf(crash("new"))))
        val daily = CompletableDeferred<Boolean>()
        val posts = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { request ->
            posts.add(request)
            if (request.path == "api/activity") daily.await() else true
        }, metadata, backgroundScope, now = { 200 })
        runCurrent(); controller.foregrounded(false); runCurrent()
        assertEquals(listOf("api/activity"), posts.map { it.path })
        assertNull(controller.state.value.question)
        controller.setPresentationAllowed(true); runCurrent()
        daily.complete(true); runCurrent()
        assertEquals(setOf("new"), controller.state.value.question!!.keys)
        assertEquals(listOf("api/activity"), posts.map { it.path })
        assertEquals(listOf("new"), store.saved.pending.map { it.key })
        controller.close()
    }

    @Test fun feedbackIsExplicitAndFailedOrEditedDraftIsNeverCleared(): Unit = runTest {
        val store = Store()
        var answer = CompletableDeferred<Boolean>()
        val requests = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { requests.add(it); answer.await() }, metadata, backgroundScope)
        runCurrent(); controller.draft("What happened"); controller.email("  fixture@example.invalid  "); runCurrent()
        assertTrue(requests.isEmpty())
        controller.sendFeedback(); runCurrent(); answer.complete(false); runCurrent()
        assertEquals("What happened", controller.state.value.draft)
        assertEquals(FeedbackStatus.FAILED, controller.state.value.feedback)
        answer = CompletableDeferred(); controller.sendFeedback(); runCurrent()
        controller.draft("New unsent words"); answer.complete(true); runCurrent()
        assertEquals("New unsent words", controller.state.value.draft)
        assertEquals(setOf("kind", "message", "email", "version", "build", "os"), requests.last().fields.keys)
        assertEquals("fixture@example.invalid", requests.last().fields["email"]!!.jsonPrimitive.content)
        controller.close()
    }

    @Test fun crashWireDropsAllFreeTextAndOnlyEmitsCodeLocations(): Unit = runTest {
        val unsafe = crash("privacy").copy(reason = "secret https://private.example typed words", frames = listOf("dev.yab.Engine.load:82", "https://private.example/secret", "user@example.com", "/data/user/secret"))
        val text = ReportWire.reportText(unsafe)
        assertTrue(text.contains("dev.yab.Engine.load:82"))
        assertFalse(text.contains("private.example")); assertFalse(text.contains("user@example")); assertFalse(text.contains("typed words")); assertFalse(text.contains("/data/user"))
        val request = ReportWire.crash(unsafe)
        assertEquals(text.toByteArray().size, request.fields["bytes"]!!.jsonPrimitive.int)
        assertEquals("android", request.fields["platform"]!!.jsonPrimitive.content)
    }

    @Test fun personProjectionClearsOnAccountEndAndRequiresALiveStringUuidSetting() {
        val row = Record("setting", "activity.person", buildJsonObject { put("value", id.uppercase()) })
        assertEquals(id, ReportPerson.project(listOf(row), "account", false))
        assertNull(ReportPerson.project(listOf(row), null, false))
        assertNull(ReportPerson.project(listOf(row), "account", true))
        assertNull(ReportPerson.project(listOf(row.copy(deleted = Stamp(1, device = "mac"))), "account", false))
        assertNull(ReportPerson.project(listOf(row.copy(fields = buildJsonObject { put("value", 123) })), "account", false))
        assertNull(ReportPerson.project(listOf(row.copy(fields = buildJsonObject { put("value", "user@example.invalid") })), "account", false))
        assertNull(ReportPerson.project(listOf(row, row), "account", false))
        assertNull(ReportPerson.project(listOf(row.copy(collection = "tab")), "account", false))
    }
}

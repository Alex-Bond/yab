package dev.yab.reports

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.*
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Literal input also compiles against source131, where the new kind is ignored. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ReportHangParityTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val metadata = ReportMetadata("0.1.0", "3", "Android", "Fixture", "dev.yab.android")
    private fun crash(key: String) = SavedCrash(key, "0.1.0", "3", "Android", "Fixture", "dev.yab.Failure",
        listOf("dev.yab.Report.$key:1"), 20)
    private fun hang(key: String): SavedCrash = json.decodeFromString(
        """{"key":"$key","version":"0.1.0","build":"3","os":"Android","device":"Fixture","reason":"ANDROID_ANR","frames":["dev.yab.Report.$key:1"],"at":20,"source":"ANDROID_EXIT","kind":"hang"}""")
    private fun header(report: SavedCrash) = json.parseToJsonElement(ReportWire.reportText(report).substringBefore('\n')).jsonObject
    private fun kind(request: ReportRequest) = request.fields["kind"]?.jsonPrimitive?.content
    private class Store(initial: ReportSnapshot = ReportSnapshot(since = 1, dailyActivity = false)) : ReportStore {
        private val codec = Json { ignoreUnknownKeys = true }
        var checkpoint = codec.encodeToString(initial)
        var fail = false
        val saved: ReportSnapshot get() = codec.decodeFromString(checkpoint)
        override suspend fun load(): ReportSnapshot { check(!fail); return saved }
        override suspend fun save(snapshot: ReportSnapshot) { check(!fail); checkpoint = codec.encodeToString(snapshot) }
    }

    // The three selected BEFORE assertions compile on the exact source131 types.
    @Test fun hangsAloneNeverAskOrSendWithoutAutomaticConsent(): Unit = runTest {
        val store = Store(); val posts = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posts.add(it); true }, metadata, backgroundScope)
        try {
            runCurrent(); controller.foregrounded(true)
            assertTrue(controller.received(listOf(hang("h1"), hang("h2")))); runCurrent()
            assertNull(controller.state.value.question)
            assertTrue(posts.isEmpty()); assertEquals(listOf("h1", "h2"), store.saved.pending.map { it.key })
            assertFalse(store.saved.automaticCrashes); assertTrue(store.saved.allowed.isEmpty())
        } finally { controller.close() }
    }

    @Test fun hangRetentionNeverEvictsFiveCrashesAndKeepsOnlyThreeHangsInStableOrder(): Unit = runTest {
        val store = Store()
        val controller = ReportsController(store, ReportTransport { error("Inactive reports must not send") }, metadata, backgroundScope)
        try {
            runCurrent()
            val input = listOf(crash("c1"), hang("h1"), crash("c2"), crash("c3"), hang("h2"),
                crash("c4"), crash("c5"), hang("h3"), crash("c6"), hang("h4"))
            assertTrue(controller.received(input)); runCurrent()
            assertEquals(listOf("c2", "c3", "h2", "c4", "c5", "h3", "c6", "h4"), store.saved.pending.map { it.key })
            assertEquals(input.map { it.key }, store.saved.seen)
            assertNull(controller.state.value.question)
        } finally { controller.close() }
    }

    @Test fun hangKindAppearsInHeaderAndEnvelopeWithoutChangingCrashWire() {
        val report = hang("h1"); val request = ReportWire.crash(report)
        assertEquals("hang", kind(request))
        assertEquals("hang", header(report)["kind"]?.jsonPrimitive?.content)
        assertEquals(ReportWire.reportText(report).toByteArray(Charsets.UTF_8).size, request.fields["bytes"]?.jsonPrimitive?.int)
        val ordinary = crash("c1")
        assertFalse(ReportWire.crash(ordinary).fields.containsKey("kind")); assertFalse(header(ordinary).containsKey("kind"))
        assertEquals(ReportWire.reportText(ordinary), ReportWire.reportText(json.decodeFromString<SavedCrash>(json.encodeToString(ordinary))))
    }

    @Test fun legacySnapshotsKeepAbsentKindAndReasonAloneDoesNotReclassifyThem() {
        val legacy = """{"since":1,"dailyActivity":false,"pending":[{"key":"old","version":"1","build":"1","os":"Android","device":"Fixture","reason":"ANDROID_ANR","frames":["dev.yab.Engine.read:8"],"at":1}],"allowed":["old"],"seen":["old"]}"""
        val restored = json.decodeFromString<ReportSnapshot>(legacy)
        val encoded = json.parseToJsonElement(json.encodeToString(restored)).jsonObject
        assertFalse(encoded["pending"]!!.jsonArray.single().jsonObject.containsKey("kind"))
        assertFalse(ReportWire.crash(restored.pending.single()).fields.containsKey("kind"))
        assertFalse(header(restored.pending.single()).containsKey("kind"))
        assertEquals(restored, json.decodeFromString<ReportSnapshot>(encoded.toString()))
        val explicit = json.parseToJsonElement(json.encodeToString(hang("new"))).jsonObject
        assertEquals("hang", explicit["kind"]?.jsonPrimitive?.content)
    }

    @Test fun sendCoversWaitingHangsAndCrashButNeverLateArrivals(): Unit = runTest {
        val store = Store(); val posts = mutableListOf<ReportRequest>(); var accepted = false
        val controller = ReportsController(store, ReportTransport { posts.add(it); accepted }, metadata, backgroundScope)
        try {
            runCurrent(); controller.foregrounded(true)
            controller.received(listOf(hang("h1"))); runCurrent(); assertNull(controller.state.value.question)
            controller.received(listOf(crash("c1"))); runCurrent()
            val original = requireNotNull(controller.state.value.question)
            assertEquals(setOf("h1", "c1"), original.keys)
            controller.received(listOf(hang("hLate"), crash("cLate"))); runCurrent()
            assertEquals(original, controller.state.value.question)
            controller.answer(original.token, true); runCurrent()
            assertEquals(setOf("h1", "c1"), store.saved.allowed)
            assertEquals(setOf("hLate", "cLate"), controller.state.value.question?.keys)
            assertEquals(1, posts.size); assertEquals("hang", kind(posts.single()))
            accepted = true; controller.tick(); runCurrent()
            assertEquals(listOf("hLate", "cLate"), store.saved.pending.map { it.key })
            assertTrue(store.saved.allowed.isEmpty()); assertFalse(store.saved.automaticCrashes)
            assertEquals(listOf("hang", "hang", null), posts.map(::kind))
        } finally { controller.close() }
    }

    @Test fun declineDropsOnlyTheOriginalMixedBatchAndOldTokenCannotAllowTheNextOne(): Unit = runTest {
        val store = Store(); var posts = 0
        val controller = ReportsController(store, ReportTransport { posts++; true }, metadata, backgroundScope)
        try {
            runCurrent(); controller.foregrounded(true)
            controller.received(listOf(hang("h1"), crash("c1"))); runCurrent()
            val original = requireNotNull(controller.state.value.question)
            assertEquals(setOf("h1", "c1"), original.keys)
            controller.received(listOf(hang("hLate"), crash("cLate"))); runCurrent()
            controller.answer(original.token, false); runCurrent()
            val next = requireNotNull(controller.state.value.question)
            assertNotEquals(original.token, next.token); assertEquals(setOf("hLate", "cLate"), next.keys)
            controller.answer(original.token, true); runCurrent()
            assertEquals(next, controller.state.value.question)
            assertEquals(listOf("hLate", "cLate"), store.saved.pending.map { it.key })
            assertTrue(store.saved.allowed.isEmpty()); assertEquals(0, posts)
            controller.received(listOf(hang("h1"), crash("c1"))); runCurrent()
            assertEquals(listOf("hLate", "cLate"), store.saved.pending.map { it.key })
        } finally { controller.close() }
    }

    @Test fun automaticSendingPreservesTheMixedQueueOrderWithoutAsking(): Unit = runTest {
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false, automaticCrashes = true))
        val posts = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posts.add(it); true }, metadata, backgroundScope)
        try {
            runCurrent(); controller.received(listOf(hang("h1"), crash("c1"), hang("h2"), crash("c2"))); runCurrent()
            assertTrue(posts.isEmpty()); controller.foregrounded(true); runCurrent()
            assertEquals(listOf("hang", null, "hang", null), posts.map(::kind))
            for ((request, key) in posts.zip(listOf("h1", "c1", "h2", "c2")))
                assertTrue(request.fields["report"]!!.jsonPrimitive.content.contains("dev.yab.Report.$key:1"))
            assertNull(controller.state.value.question); assertTrue(store.saved.pending.isEmpty())
            controller.tick(); runCurrent(); assertEquals(4, posts.size)
        } finally { controller.close() }
    }

    @Test fun anAllowedHangRetriesAloneAfterRelaunchWithoutAskingOrEnablingAutomatic(): Unit = runTest {
        val store = Store(); val firstPosts = mutableListOf<ReportRequest>()
        val first = ReportsController(store, ReportTransport { firstPosts.add(it); kind(it) != "hang" }, metadata, backgroundScope)
        runCurrent(); first.foregrounded(true); first.received(listOf(crash("c1"), hang("h1"))); runCurrent()
        first.answer(requireNotNull(first.state.value.question).token, true); runCurrent()
        assertEquals(listOf("h1"), store.saved.pending.map { it.key }); assertEquals(setOf("h1"), store.saved.allowed)
        assertFalse(store.saved.automaticCrashes); assertEquals(listOf(null, "hang"), firstPosts.map(::kind)); first.close()
        val retried = mutableListOf<ReportRequest>()
        val next = ReportsController(store, ReportTransport { retried.add(it); true }, metadata, backgroundScope)
        try {
            runCurrent(); next.foregrounded(true); runCurrent()
            assertNull(next.state.value.question); assertEquals(listOf("hang"), retried.map(::kind))
            assertTrue(store.saved.pending.isEmpty()); assertTrue(store.saved.allowed.isEmpty()); assertFalse(store.saved.automaticCrashes)
        } finally { next.close() }
    }

    @Test fun newKindCannotBypassAbsentSiteOrFailedStorage(): Unit = runTest {
        for (broken in listOf(false, true)) {
            val store = Store(ReportSnapshot()).apply { fail = broken }; var posts = 0
            val controller = ReportsController(store, if (broken) ReportTransport { posts++; true } else null, metadata, backgroundScope)
            try {
                runCurrent(); controller.foregrounded(true)
                assertFalse(controller.received(listOf(hang("h1"), crash("c1")))); runCurrent()
                assertNull(controller.state.value.question); assertEquals(0, posts)
                assertFalse(controller.state.value.available); assertNull(store.saved.installation)
            } finally { controller.close() }
        }
    }

    @Test fun firstEligibleLaunchMarksMixedBacklogSeenWithoutQuestionOrSend(): Unit = runTest {
        val store = Store(ReportSnapshot(dailyActivity = false)); val posts = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posts.add(it); true }, metadata, backgroundScope, now = { 100 })
        try {
            runCurrent(); controller.foregrounded(true)
            assertTrue(controller.received(listOf(hang("h1"), crash("c1")))); runCurrent()
            assertEquals(listOf("h1", "c1"), store.saved.seen); assertTrue(store.saved.pending.isEmpty())
            assertNull(controller.state.value.question); assertTrue(posts.isEmpty()); assertEquals(100L, store.saved.since)
        } finally { controller.close() }
    }

    @Test fun hangWireKeepsExistingCodeOnlyPrivacyWithoutInventingDuration() {
        val report = hang("h1").copy(reason = "secret https://private.example typed words",
            frames = listOf("dev.yab.Engine.read:8", "https://private.example/path", "user@example.invalid", "/data/user/private"))
        val request = ReportWire.crash(report); val text = request.fields.toString()
        assertTrue(text.contains("dev.yab.Engine.read:8")); assertEquals("hang", kind(request))
        for (secret in listOf("private.example", "typed words", "user@example", "/data/user")) assertFalse(text.contains(secret))
        assertEquals(setOf("platform", "version", "build", "os", "device", "report", "bytes", "kind"), request.fields.keys)
        assertFalse(header(report).containsKey("ms"))
        val body = json.parseToJsonElement(ReportWire.reportText(report).substringAfter('\n')).jsonObject
        assertFalse(body.containsKey("hang")); assertFalse(body.containsKey("ms"))
    }

    @Test fun independentEvictionPrunesAllowedKeysAndSeenReportsCannotReenter(): Unit = runTest {
        val initial = listOf(crash("c1"), hang("h1"), crash("c2"), hang("h2"), crash("c3"), hang("h3"), crash("c4"), crash("c5"))
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false, pending = initial,
            allowed = setOf("c1", "h1", "c2", "h2"), seen = initial.map { it.key }))
        val controller = ReportsController(store, ReportTransport { error("Inactive reports must not send") }, metadata, backgroundScope)
        try {
            runCurrent(); assertTrue(controller.received(listOf(hang("h4"), crash("c6")))); runCurrent()
            val retained = listOf("c2", "h2", "c3", "h3", "c4", "c5", "h4", "c6")
            assertEquals(retained, store.saved.pending.map { it.key }); assertEquals(setOf("c2", "h2"), store.saved.allowed)
            controller.received(listOf(hang("h1"), crash("c1"))); runCurrent()
            assertEquals(retained, store.saved.pending.map { it.key })
            assertEquals(initial.map { it.key } + listOf("h4", "c6"), store.saved.seen)
        } finally { controller.close() }
    }

    @Test fun backgroundOrBlockedPresentationRefusesSavedMixedQuestionAnswers(): Unit = runTest {
        val store = Store(); var posts = 0
        val controller = ReportsController(store, ReportTransport { posts++; true }, metadata, backgroundScope)
        try {
            runCurrent(); controller.foregrounded(false)
            controller.received(listOf(hang("h1"), crash("c1"))); runCurrent(); assertNull(controller.state.value.question)
            controller.setPresentationAllowed(true); runCurrent()
            val original = requireNotNull(controller.state.value.question)
            controller.backgrounded(); controller.answer(original.token, true); runCurrent()
            assertNull(controller.state.value.question); assertTrue(store.saved.allowed.isEmpty()); assertEquals(0, posts)
            controller.foregrounded(true); runCurrent(); val fresh = requireNotNull(controller.state.value.question)
            assertNotEquals(original.token, fresh.token)
            controller.setPresentationAllowed(false); controller.answer(fresh.token, true); runCurrent()
            assertNull(controller.state.value.question); assertTrue(store.saved.allowed.isEmpty()); assertEquals(0, posts)
            assertEquals(listOf("h1", "c1"), store.saved.pending.map { it.key })
        } finally { controller.close() }
    }

    @Test fun heldCrashAckKeepsItsSeenKeyAcrossAFullWindowOfLateHangs(): Unit = runTest {
        val original = crash("a")
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false,
            pending = listOf(original), allowed = setOf(original.key), seen = listOf(original.key)))
        val release = CompletableDeferred<Boolean>(); val posted = mutableListOf<ReportRequest>()
        val controller = ReportsController(store, ReportTransport { posted.add(it); release.await() }, metadata, backgroundScope)
        try {
            runCurrent(); controller.foregrounded(true); runCurrent()
            assertEquals(1, posted.size)
            assertTrue(controller.received((1..199).map { hang("h$it") })); runCurrent()
            assertEquals(200, store.saved.seen.size)
            assertTrue(controller.received(listOf(hang("b")))); runCurrent()
            release.complete(true); runCurrent()
            val originalWasSeenAfterAck = original.key in store.saved.seen
            assertTrue(controller.received(listOf(original))); runCurrent()
            assertTrue("The acknowledged original crash must not reenter after late hangs fill the seen window",
                store.saved.pending.none { it.key == original.key })
            assertTrue("A held pending crash must keep its seen identity through its ACK", originalWasSeenAfterAck)
            assertEquals(listOf("h198", "h199", "b"), store.saved.pending.map { it.key })
            assertEquals(listOf("a") + (2..199).map { "h$it" } + "b", store.saved.seen)
            assertNull(controller.state.value.question); assertEquals(1, posted.size)
        } finally { controller.close(); release.cancel() }
    }

    @Test fun loadedPendingWithoutSeenCannotDuplicateItsOriginalReportOnReimport(): Unit = runTest {
        val original = crash("loaded")
        val store = Store(ReportSnapshot(since = 1, dailyActivity = false,
            pending = listOf(original), allowed = setOf(original.key), seen = emptyList()))
        val controller = ReportsController(store, ReportTransport { error("Inactive reports must not post") }, metadata, backgroundScope)
        try {
            runCurrent(); assertTrue(controller.received(listOf(original))); runCurrent()
            assertEquals("A loaded pending identity already owns its report", listOf(original), store.saved.pending)
            assertEquals(listOf(original.key), store.saved.seen)
            assertEquals(setOf(original.key), store.saved.allowed)
            assertNull(controller.state.value.question)
        } finally { controller.close() }
        val legacy = (1..205).map { crash("legacy$it") }
        val legacyStore = Store(ReportSnapshot(dailyActivity = false, pending = legacy))
        val restored = ReportsController(legacyStore, ReportTransport { error("Inactive legacy reports must not post") }, metadata, backgroundScope)
        try {
            runCurrent(); assertTrue(restored.received(emptyList())); runCurrent()
            assertEquals(legacy, legacyStore.saved.pending)
            assertEquals(200, legacyStore.saved.seen.size)
            assertEquals(legacy.takeLast(200).map { it.key }, legacyStore.saved.seen)
            assertTrue(restored.state.value.available)
        } finally { restored.close() }
    }
}

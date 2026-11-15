package dev.yab.core

import dev.yab.core.sync.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import kotlin.random.Random

class JournalTest {
    private fun fields(vararg entries: Pair<String, JsonElement>) = JsonObject(entries.toMap())
    @Test fun mergedFieldsAndRemovalRulesMatchSwift() {
        val base = Record("tab", "one").updated(fields("url" to JsonPrimitive("https://site.test"), "parent" to JsonPrimitive("space"), "order" to JsonPrimitive("V")), Clock("a", now = { 100 }))
        val a = base.updated(JsonObject(base.visible + ("title" to JsonPrimitive("Title"))), Clock("a", now = { 101 }))
        val b = base.updated(JsonObject(base.visible + mapOf("parent" to JsonPrimitive("other"), "seen" to JsonPrimitive(50))), Clock("b", now = { 102 }))
        val merged = a.merged(b)
        assertEquals(merged, b.merged(a)); assertEquals(JsonPrimitive("Title"), merged["title"])
        assertEquals(JsonPrimitive("other"), merged["parent"])
        assertEquals(b.stamps["parent"], merged.stamps["order"])
        assertFalse(merged.merged(base.removed(Stamp(99, device = "a"))).alive())
        val bookmark = Record("bookmark", "b").removed(Stamp(100, device = "a"))
        assertTrue(bookmark.updated(fields("url" to JsonPrimitive("url")), Clock("b", now = { 101 })).alive())
        val future = Record.parse("""{"collection":"future","id":"x","fields":{"nested":{"x":[true,2,null]}},"stamps":{"nested":{"wall":1,"count":0,"device":"a"}},"schema":9,"unrecognized":{"v":3}}""")
        assertEquals(future, Record.parse(future.toJson().toString()))
    }
    @Test fun clockIgnoresFutureDriftAndRemainsMonotonic() {
        val clock = Clock("android", now = { 100 })
        assertTrue(clock.observe(Stamp(200, 5, "mac")))
        assertEquals(Stamp(200, 6, "android"), clock.tick())
        assertFalse(clock.observe(Stamp(Clock.DRIFT + 101, device = "mac")))
        assertEquals(Stamp(200, 7, "android"), clock.tick())
    }
    @Test fun fileJournalKeepsOutboxCursorClockReceiptsAndRejectsOtherOwners() {
        val dir = Files.createTempDirectory("yab-journal").toFile(); val file = dir.resolve("journal.json"); val key = RecordKey("tab", "one")
        try {
            val first = FileJournal(file, "a", "account", now = { 100 }).use { journal ->
                val record = journal.change(key, fields("title" to JsonPrimitive("One")))
                journal.receive(emptyList(), 23); assertTrue(journal.reserveReceipt("open-once")); assertFalse(journal.reserveReceipt("open-once"))
                assertThrows(Exception::class.java) { FileJournal(file, "a", "account") }
                record
            }
            FileJournal(file, "a", "account", now = { 50 }).use { journal ->
                assertEquals(23L, journal.cursor); assertEquals(first, journal.pending().single().record); assertTrue(journal.hasReceipt("open-once"))
                val second = journal.change(key, fields("title" to JsonPrimitive("Two")))
                assertTrue(second.stamps["title"]!! > first.stamps["title"]!!)
                journal.sent(listOf(VersionedRecord(first, 1)), 24); assertEquals(1, journal.pending().size)
                journal.sent(listOf(VersionedRecord(second, 2)), 25); assertTrue(journal.pending().isEmpty())
            }
            assertThrows(IllegalArgumentException::class.java) { FileJournal(file, "b", "account") }
            assertThrows(IllegalArgumentException::class.java) { FileJournal(file, "a", "different-account") }
            file.writeText("{")
            assertThrows(Exception::class.java) { FileJournal(file, "a", "account") }
        } finally { dir.deleteRecursively() }
    }
    @Test fun aCommitOnALargeJournalAddsOnlyWhatChanged() {
        val dir = Files.createTempDirectory("yab-journal").toFile(); val file = dir.resolve("journal.json")
        try {
            FileJournal(file, "a", "account").use { journal ->
                journal.receive((0 until 2000).map { VersionedRecord(Record("chatitem", "$it", fields("text" to JsonPrimitive("word ".repeat(40))), mapOf("text" to Stamp(5, device = "mac"))), it.toLong()) }, 2000)
                val base = file.lastModified(); val size = dir.listFiles()!!.sumOf { it.length() }
                journal.change(RecordKey("tab", "one"), fields("title" to JsonPrimitive("One")))
                assertEquals(base, file.lastModified())
                assertTrue(dir.listFiles()!!.sumOf { it.length() } - size < 1024)
            }
            FileJournal(file, "a", "account").use { journal ->
                assertEquals(2000L, journal.cursor); assertEquals(2001, journal.all().size)
                assertEquals("One", (journal.record(RecordKey("tab", "one"))!!["title"] as JsonPrimitive).content)
            }
        } finally { dir.deleteRecursively() }
    }
    @Test fun aCommitCutShortByTheProcessDyingIsDroppedAndLaterCommitsStillLoad() {
        val dir = Files.createTempDirectory("yab-journal").toFile(); val file = dir.resolve("journal.json")
        try {
            FileJournal(file, "a", "account").use { journal ->
                journal.change(RecordKey("tab", "one"), fields("title" to JsonPrimitive("One")))
                journal.change(RecordKey("tab", "two"), fields("title" to JsonPrimitive("Two")))
            }
            dir.listFiles { _, name -> name.endsWith(".log") }!!.single().appendText("{\"cursor\":9,\"rows\":[{\"rec")
            FileJournal(file, "a", "account").use { journal ->
                assertEquals(0L, journal.cursor); assertEquals(2, journal.all().size)
                journal.change(RecordKey("tab", "three"), fields("title" to JsonPrimitive("Three")))
            }
            FileJournal(file, "a", "account").use { assertEquals(3, it.all().size) }
        } finally { dir.deleteRecursively() }
    }
    @Test fun aLogLeftBehindARewriteIsNeverReplayed() {
        val dir = Files.createTempDirectory("yab-journal").toFile(); val file = dir.resolve("journal.json")
        try {
            FileJournal(file, "a", "account").use { journal ->
                journal.change(RecordKey("tab", "one"), fields("title" to JsonPrimitive("Old")))
                journal.change(RecordKey("tab", "one"), fields("title" to JsonPrimitive("Older commit")))
            }
            val old = dir.listFiles { _, name -> name.endsWith(".log") }!!.single(); val kept = old.readText()
            FileJournal(file, "a", "account").use { journal ->
                journal.receive((0 until 8000).map { VersionedRecord(Record("chatitem", "$it", fields("text" to JsonPrimitive("word ".repeat(200))), mapOf("text" to Stamp(5, device = "mac"))), it.toLong()) }, 8000)
                journal.change(RecordKey("tab", "one"), fields("title" to JsonPrimitive("New")))
            }
            old.writeText(kept)
            FileJournal(file, "a", "account").use { assertEquals("New", (it.record(RecordKey("tab", "one"))!!["title"] as JsonPrimitive).content) }
        } finally { dir.deleteRecursively() }
    }
    @Test fun aJournalInTheOldWholeFileShapeOpensAndMovesOn() {
        val dir = Files.createTempDirectory("yab-journal").toFile(); val file = dir.resolve("journal.json")
        try {
            val record = Record("tab", "one", fields("title" to JsonPrimitive("One")), mapOf("title" to Stamp(5, device = "a")))
            file.writeText(buildJsonObject {
                put("format", 1); put("device", "a"); put("account", "account"); put("cursor", 7); put("clock", Stamp(5, device = "a").toJson())
                put("rows", buildJsonArray { add(buildJsonObject { put("record", record.toJson()); put("dirty", false); put("version", 3) }) })
                put("receipts", buildJsonArray { add("kept") })
            }.toString())
            FileJournal(file, "a", "account").use { journal ->
                assertEquals(7L, journal.cursor); assertEquals(record, journal.record(record.key)); assertTrue(journal.hasReceipt("kept"))
                journal.change(RecordKey("tab", "two"), fields("title" to JsonPrimitive("Two")))
            }
            FileJournal(file, "a", "account").use { assertEquals(2, it.all().size); assertEquals(7L, it.cursor); assertTrue(it.hasReceipt("kept")) }
        } finally { dir.deleteRecursively() }
    }
    @Test fun threeDevicesConvergeAcrossOfflineRandomizedEditsAndDuplicateDelivery() {
        repeat(100) { seed ->
            val random = Random(seed); var now = 100L
            val devices = listOf("a", "b", "c").map { MemoryJournal(it, now = { ++now }) }
            val server = mutableMapOf<RecordKey, Record>()
            fun push(journal: Journal) { val sent = journal.pending(); for ((record, _) in sent) server[record.key] = server[record.key]?.merged(record) ?: record; journal.sent(sent.map { it.copy(version = 1) }) }
            fun pull(journal: Journal) { val incoming = server.values.shuffled(random).map { VersionedRecord(it, 1) }; journal.receive(incoming + incoming.take(1)) }
            repeat(80) {
                val journal = devices.random(random); val key = RecordKey(if (random.nextBoolean()) "tab" else "bookmark", "r${random.nextInt(6)}")
                when (random.nextInt(5)) {
                    0, 1 -> journal.change(key, fields("title" to JsonPrimitive("T${random.nextInt(5)}"), "parent" to JsonPrimitive("s${random.nextInt(3)}"), "order" to JsonPrimitive(Order.between(null, null))))
                    2 -> journal.remove(key)
                    3 -> push(journal)
                    else -> pull(journal)
                }
            }
            repeat(2) { devices.forEach(::push); devices.forEach(::pull) }
            assertEquals("Seed $seed", devices[0].all(), devices[1].all()); assertEquals(devices[1].all(), devices[2].all())
            assertTrue(devices.all { it.pending().isEmpty() })
        }
    }

    @Test fun conditionalCloseRejectsANewerReceiveThenPersistsTheFreshRemovalAndOutbox() {
        val directory = Files.createTempDirectory("conditional-close").toFile(); val file = directory.resolve("journal.json")
        val key = RecordKey("tab", "mac-today"); val macClock = Clock("mac", now = { 100 })
        val shown = Record(key.collection, key.id).updated(fields("device" to JsonPrimitive("mac"), "url" to JsonPrimitive("https://before.test")), macClock)
        val received = shown.updated(JsonObject(shown.visible + ("url" to JsonPrimitive("https://after.test"))), macClock)
        try {
            val removed = FileJournal(file, "android", "account", now = { 101 }).use { journal ->
                journal.receive(listOf(VersionedRecord(shown, 1)), 1)
                // A real receive committed after rendering, before the user's Close write.
                journal.receive(listOf(VersionedRecord(received, 2)), 2)
                assertThrows(IllegalArgumentException::class.java) { journal.removeConditionally(key, mapOf(key to shown)) }
                assertEquals(received, journal.record(key)); assertTrue(journal.pending().isEmpty())
                val close = checkNotNull(journal.removeConditionally(key, mapOf(key to received)))
                assertFalse(close.alive()); assertEquals("android", close.deleted!!.device)
                assertEquals(2L, journal.cursor); assertEquals(VersionedRecord(close, 2), journal.pending().single())
                close
            }
            FileJournal(file, "android", "account", now = { 50 }).use { journal ->
                assertEquals(removed, journal.record(key)); assertEquals(VersionedRecord(removed, 2), journal.pending().single())
                journal.receive(listOf(VersionedRecord(received, 2)), 2)
                assertFalse(journal.record(key)!!.alive()); assertTrue(journal.isPending(key))
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun conditionalCloseChecksEveryExpectedRecordBeforeMakingAnyMutation() {
        MemoryJournal("android", now = { 101 }).use { journal ->
            val tab = Record("tab", "one").updated(fields("device" to JsonPrimitive("mac")), Clock("mac", now = { 100 }))
            val owner = Record("commandcap", "mac").updated(fields("device" to JsonPrimitive("mac"), "androidSync" to JsonPrimitive(1)), Clock("mac", now = { 100 }))
            journal.receive(listOf(VersionedRecord(tab, 1), VersionedRecord(owner, 1)))
            journal.receive(listOf(VersionedRecord(owner.removed(Stamp(102, device = "mac")), 2)))
            assertThrows(IllegalArgumentException::class.java) { journal.removeConditionally(tab.key, mapOf(tab.key to tab, owner.key to owner)) }
            assertEquals(tab, journal.record(tab.key)); assertTrue(journal.pending().isEmpty())
        }
    }
}

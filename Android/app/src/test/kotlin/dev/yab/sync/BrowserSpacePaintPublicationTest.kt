package dev.yab.sync

import dev.yab.browser.model.*
import dev.yab.core.sync.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Exercises the actual codec → serial publication → CRDT write boundary. */
class BrowserSpacePaintPublicationTest {
    private val id = "00000000-0000-0000-0000-000000000001"
    private val key = RecordKey("space", id)
    private fun paint() = buildJsonObject {
        put("swatch", "custom"); put("color", "#112233"); put("grain", false); put("grainAmount", .1)
        put("transparency", .7); put("future", buildJsonObject { put("mode", "old") })
    }
    private fun record() = Record("space", id).updated(buildJsonObject {
        put("name", "Personal"); put("icon", "star.fill"); put("order", "A"); put("paint", paint())
        put("search", "future-engine"); put("other", "preserve")
    }, Clock("mac", now = { 100 }))
    private fun local() = BrowserSnapshot(spaces = listOf(BrowserSpace(id, "Personal")), selectedSpaceId = id)
    private fun journal(original: Record) = MemoryJournal("android", now = { 1_000 }).also {
        it.receive(listOf(VersionedRecord(original, 1)))
    }
    private fun changed(before: BrowserSnapshot, look: BrowserSpaceLook, records: List<Record>) =
        BrowserSyncCodec.changes(before.copy(spaces = before.spaces.map { it.copy(look = look.raw, color = look.primary) }), before, records, "android")
    private fun write(store: Journal, changes: BrowserSyncCodec.Changes) {
        checkNotNull(BrowserSyncPublication.publish(changes.fields, changes.removed, "account", 7,
            { "account" }, { 7 }, { false }, { store }, changes.paintEdits) { publication ->
            publication.journal.changeBatch(publication.fields)
        })
    }

    @Test fun aLateRemotePaletteAndUnknownFieldWinWhileOnlyTheEditedGrainIsPublished() {
        val original = record()
        journal(original).use { store ->
            val before = BrowserSyncCodec.project(local(), store.all(), "android")
            assertEquals(paint(), before.spaces.single().look)
            val changes = changed(before, BrowserSpaceLook.from(before.spaces.single().look).grain(.75), store.all())
            assertEquals(setOf("grain", "grainAmount"), changes.paintEdits[key]!!.fields.keys)
            val freshPaint = JsonObject(paint() + mapOf("color" to JsonPrimitive("#ABCDEF"), "future" to JsonPrimitive("new"), "newField" to JsonPrimitive(19)))
            val arrived = original.updated(JsonObject(original.visible + ("paint" to freshPaint)), Clock("mac", now = { 200 }))
            store.receive(listOf(VersionedRecord(arrived, 2)))
            write(store, changes)
            val saved = store.record(key)!!
            assertEquals(JsonObject(freshPaint + mapOf("grain" to JsonPrimitive(true), "grainAmount" to JsonPrimitive(.75))), saved["paint"])
            assertEquals(original["search"], saved["search"]); assertEquals(original.stamps["search"], saved.stamps["search"])
            assertEquals(original["other"], saved["other"]); assertEquals(original.stamps["other"], saved.stamps["other"])
            val projected = BrowserSyncCodec.project(before, store.all(), "android")
            assertEquals(saved["paint"], projected.spaces.single().look)
        }
    }

    @Test fun aRemotePaintClearDoesNotResurrectOldUnknownFieldsOrTransparency() {
        val original = record()
        journal(original).use { store ->
            val before = BrowserSyncCodec.project(local(), store.all(), "android")
            val changes = changed(before, BrowserSpaceLook.from(before.spaces.single().look).grain(.4), store.all())
            val cleared = original.updated(JsonObject(original.visible.filterKeys { it != "paint" }), Clock("mac", now = { 200 }))
            store.receive(listOf(VersionedRecord(cleared, 2))); write(store, changes)
            val saved = store.record(key)!!["paint"]!!.jsonObject
            assertEquals(setOf("swatch", "color", "grain", "grainAmount"), saved.keys)
            assertEquals(JsonPrimitive("#112233"), saved["color"])
            assertFalse(saved.containsKey("future")); assertFalse(saved.containsKey("transparency"))
        }
    }

    @Test fun renamingAnInvalidOrLegacyLookNeverNormalizesOrRestampsItsRawPaint() {
        for (raw in listOf(paint(), buildJsonObject { put("wash", "#FDFDFD"); put("future", JsonArray(listOf(JsonPrimitive("opaque")))) })) {
            val original = record().updated(JsonObject(record().visible + ("paint" to raw)), Clock("mac", now = { 150 }))
            journal(original).use { store ->
                val before = BrowserSyncCodec.project(local(), store.all(), "android")
                val after = before.copy(spaces = before.spaces.map { it.copy(name = "Renamed") })
                val changes = BrowserSyncCodec.changes(after, before, store.all(), "android")
                assertTrue(changes.paintEdits.isEmpty()); assertFalse(changes.fields[key]!!.containsKey("paint"))
                write(store, changes)
                assertEquals(raw, store.record(key)!!["paint"]); assertEquals(original.stamps["paint"], store.record(key)!!.stamps["paint"])
            }
        }
    }

    @Test fun stalePaintPublicationIsRejectedBeforeJournalLookupAndUnknownIntentIsNeverRead() {
        var accesses = 0
        val fields = mapOf(key to buildJsonObject { put("paint", paint()) })
        val edits = mapOf(key to BrowserPaintEdit(mapOf("grainAmount" to JsonPrimitive(.8)), paint()))
        for ((account, epoch, removed) in listOf(Triple("other", 7L, false), Triple("account", 8L, false), Triple("account", 7L, true))) {
            assertThrows(IllegalStateException::class.java) {
                BrowserSyncPublication.prepare(fields, emptySet(), "account", 7, { account }, { epoch }, { removed }, { accesses++; null }, edits)
            }
        }
        assertEquals(0, accesses)
        journal(record()).use { store ->
            var reads = 0
            val counted = object : Journal by store { override fun record(key: RecordKey): Record? { reads++; return store.record(key) } }
            assertThrows(IllegalArgumentException::class.java) {
                BrowserSyncPublication.prepare(fields, emptySet(), "account", 7, { "account" }, { 7 }, { false }, { counted },
                    mapOf(key to BrowserPaintEdit(mapOf("future" to JsonPrimitive("forbidden")), paint())))
            }
            assertEquals(0, reads); assertTrue(store.pending().isEmpty())
        }
    }

    @Test fun aRemoteReceiverCannotEnterBetweenProductionPaintMergeAndWrite() {
        val original = record()
        journal(original).use { store ->
            val before = BrowserSyncCodec.project(local(), store.all(), "android")
            val changes = changed(before, BrowserSpaceLook.from(before.spaces.single().look).grain(.75), store.all())
            val newPaint = JsonObject(paint() + mapOf("color" to JsonPrimitive("#FEDCBA"), "remoteOnly" to JsonPrimitive(23)))
            val arrived = original.updated(JsonObject(original.visible + ("paint" to newPaint)), Clock("mac", now = { 2_000 }))
            val enter = CountDownLatch(1); val attempting = CountDownLatch(1); val received = CountDownLatch(1)
            val error = AtomicReference<Throwable?>(null)
            val receiver = Thread {
                try { check(enter.await(2, TimeUnit.SECONDS)); attempting.countDown(); store.receive(listOf(VersionedRecord(arrived, 2))) }
                catch (failure: Throwable) { error.set(failure) }
                finally { received.countDown() }
            }
            receiver.start()
            try {
                BrowserSyncPublication.publish(changes.fields, changes.removed, "account", 7, { "account" }, { 7 }, { false }, { store }, changes.paintEdits) { publication ->
                    enter.countDown(); assertTrue(attempting.await(2, TimeUnit.SECONDS))
                    assertFalse("receive entered the actual Journal merge/write critical section", received.await(100, TimeUnit.MILLISECONDS))
                    assertEquals(original, store.record(key))
                    publication.journal.changeBatch(publication.fields)
                    assertEquals(JsonPrimitive(.75), store.record(key)!!["paint"]!!.jsonObject["grainAmount"])
                }
                assertTrue(received.await(2, TimeUnit.SECONDS)); receiver.join(2_000)
                assertFalse(receiver.isAlive); assertNull(error.get())
                assertEquals(arrived["paint"], store.record(key)!!["paint"])
            } finally { enter.countDown(); receiver.interrupt(); receiver.join(2_000) }
        }
    }

    @Test fun deletedExistingSpacesAreSkippedWithoutBlockingOtherWritesOrWeakeningCallerCas() {
        val original = record()
        journal(original).use { store ->
            val before = BrowserSyncCodec.project(local(), store.all(), "android")
            val changes = changed(before, BrowserSpaceLook.from(before.spaces.single().look).grain(.5), store.all())
            var admitted = 0
            assertThrows(IllegalArgumentException::class.java) {
                BrowserSyncPublication.publish(changes.fields, changes.removed, "account", 7, { "account" }, { 7 }, { false }, { store }, changes.paintEdits, expected = mapOf(key to null)) {
                    admitted++
                    it.journal.changeBatch(it.fields, mapOf(key to null))
                }
            }
            assertEquals(0, admitted)
            assertTrue(store.pending().isEmpty()); assertEquals(original, store.record(key))
            val removed = original.removed(Stamp(300, device = "mac"))
            store.receive(listOf(VersionedRecord(removed, 2)))
            assertFalse(store.record(key)!!.alive())
            write(store, changes)
            assertEquals(removed, store.record(key)); assertTrue(store.pending().isEmpty())
            val other = RecordKey("setting", "syncHistory")
            val fields = changes.fields + (other to buildJsonObject { put("value", false) })
            BrowserSyncPublication.publish(fields, emptySet(), "account", 7, { "account" }, { 7 }, { false }, { store }, changes.paintEdits) {
                it.journal.changeBatch(it.fields)
            }
            assertEquals(removed, store.record(key)); assertNotNull(store.record(other))
            // Name/Emoji use the same existing-space admission, without a paint intent.
            BrowserSyncPublication.publish(mapOf(key to buildJsonObject { put("name", "Must not return"); put("icon", "🌱") }), emptySet(),
                "account", 7, { "account" }, { 7 }, { false }, { store }) { it.journal.changeBatch(it.fields) }
            assertEquals(removed, store.record(key))
        }
        MemoryJournal("android").use { store ->
            val edit = BrowserPaintEdit(mapOf("grain" to JsonPrimitive(true)), paint())
            BrowserSyncPublication.publish(mapOf(key to buildJsonObject { put("paint", paint()) }), emptySet(), "account", 7,
                { "account" }, { 7 }, { false }, { store }, mapOf(key to edit)) { it.journal.changeBatch(it.fields) }
            assertTrue(store.all().isEmpty()); assertTrue(store.pending().isEmpty())
        }
    }

    @Test fun absentAndExplicitNestedNullRemainDistinctThroughCodecAndProductionPublication() {
        for (explicitNull in listOf(false, true)) {
            val raw = JsonObject(paint() + mapOf("drawingsStrength" to JsonPrimitive(.6), "unknownNull" to JsonNull))
            val original = record().updated(JsonObject(record().visible + ("paint" to raw)), Clock("mac", now = { 150 }))
            journal(original).use { store ->
                val before = BrowserSyncCodec.project(local(), store.all(), "android")
                val edited = if (explicitNull) JsonObject(raw + ("drawingsStrength" to JsonNull)) else JsonObject(raw - "drawingsStrength")
                val changes = changed(before, BrowserSpaceLook.from(edited), store.all())
                val intent = changes.paintEdits[key]!!.fields
                assertTrue(intent.containsKey("drawingsStrength"))
                assertEquals(if (explicitNull) JsonNull else null, intent["drawingsStrength"])
                write(store, changes)
                val saved = store.record(key)!!["paint"]!!.jsonObject
                assertEquals(explicitNull, saved.containsKey("drawingsStrength"))
                assertEquals(if (explicitNull) JsonNull else null, saved["drawingsStrength"])
                assertTrue(saved.containsKey("unknownNull")); assertEquals(JsonNull, saved["unknownNull"])
            }
        }
    }

    @Test fun acquiringTheJournalMonitorRechecksTheSameExpectedOwnerBeforeReadingRecords() {
        journal(record()).use { store ->
            var ownerReads = 0; var journalReads = 0; var operations = 0
            assertThrows(IllegalStateException::class.java) {
                BrowserSyncPublication.publish(mapOf(key to buildJsonObject { put("name", "Wrong source") }), emptySet(), "account", 7,
                    { ownerReads++; if (ownerReads == 1) "account" else "other" }, { 7 }, { false }, { journalReads++; store }) {
                    operations++; it.journal.changeBatch(it.fields)
                }
            }
            assertEquals(2, ownerReads); assertEquals(1, journalReads); assertEquals(0, operations)
            assertEquals(record(), store.record(key)); assertTrue(store.pending().isEmpty())
        }
    }
}

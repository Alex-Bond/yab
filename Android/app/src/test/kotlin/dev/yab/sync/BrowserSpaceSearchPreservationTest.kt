package dev.yab.sync

import dev.yab.browser.model.*
import dev.yab.core.sync.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Current Phone carries the Mac's space search fields but still searches with global Settings.
 * Exercise the actual mobile publication preparation and CRDT journal, including field stamps. */
class BrowserSpaceSearchPreservationTest {
    private val id = "00000000-0000-0000-0000-000000000001"
    private val other = "00000000-0000-0000-0000-000000000002"
    private val key = RecordKey("space", id)
    private fun space(search: String? = "custom", custom: String? = "https://mac-search.invalid/?q=%s") =
        Record("space", id, unknown = buildJsonObject { put("futureRecordMetadata", "opaque") }).updated(buildJsonObject {
            put("name", "Personal"); put("icon", "star.fill"); put("order", "A"); put("ownSignIns", true)
            put("paint", buildJsonObject { put("color", "#EEEEEE"); put("grainAmount", .4); put("futureEffect", true) })
            search?.let { put("search", it) }; custom?.let { put("searchCustom", it) }
            put("futureSpaceField", buildJsonObject { put("mode", "future"); put("version", 3) })
        }, Clock("mac", now = { 100 }))
    private fun journal(vararg records: Record) = MemoryJournal("android", now = { 1_000 }).also {
        it.receive(records.map { record -> VersionedRecord(record, 1) })
    }
    private fun local(settings: BrowserSettings = BrowserSettings()) = BrowserSnapshot(
        spaces = listOf(BrowserSpace(id, "Personal")), selectedSpaceId = id, settings = settings)
    private fun prepare(store: Journal, changes: Map<RecordKey, JsonObject>) = checkNotNull(BrowserSyncPublication.prepare(
        changes, emptySet(), "account", 7, { "account" }, { 7 }, { false }, { store }))
    private fun rename(snapshot: BrowserSnapshot) = snapshot.copy(spaces = snapshot.spaces.map { space ->
        if (space.id == id) space.copy(name = "Renamed on Android") else space
    })

    @Test fun renameLookAndReorderRoundTripExactMacSearchAndUnknownFieldsWithoutRestampingThem() {
        val original = space()
        val second = Record("space", other).updated(buildJsonObject { put("name", "Work"); put("order", "Z") }, Clock("mac", now = { 100 }))
        journal(original, second).use { store ->
            val before = BrowserSyncCodec.project(local(), store.all(), "android")
            val changed = before.copy(spaces = before.spaces.reversed().map {
                if (it.id == id) it.copy(name = "Renamed on Android", color = 0xFF112233) else it
            })
            val patch = BrowserSyncCodec.changes(changed, before, store.all(), "android")
            val edit = checkNotNull(patch.fields[key])
            assertTrue(edit.containsKey("name")); assertTrue(edit.containsKey("paint")); assertTrue(edit.containsKey("order"))
            assertFalse(edit.containsKey("search")); assertFalse(edit.containsKey("searchCustom"))
            val publication = prepare(store, patch.fields)
            publication.journal.changeBatch(publication.fields)
            val saved = checkNotNull(store.record(key))
            for (name in listOf("search", "searchCustom", "futureSpaceField")) {
                assertEquals(original[name], saved[name]); assertEquals(original.stamps[name], saved.stamps[name])
            }
            assertEquals(original.unknown, saved.unknown)
            assertEquals(JsonPrimitive(true), saved["paint"]!!.jsonObject["futureEffect"])
            assertEquals(JsonPrimitive("#112233"), saved["paint"]!!.jsonObject["color"])
            assertEquals(saved, Record.parse(saved.toJson().toString()))
            val projected = BrowserSyncCodec.project(changed, store.all(), "android")
            assertTrue(BrowserSyncCodec.changes(projected, projected, store.all(), "android").fields.isEmpty())
        }
    }

    @Test fun oldAndNewDefaultSpacesNeverAcquireAnImplicitPerSpaceSearchChoice() {
        val original = space(null, null)
        journal(original).use { store ->
            val before = BrowserSyncCodec.project(local(), store.all(), "android")
            val changes = BrowserSyncCodec.changes(rename(before), before, store.all(), "android")
            val publication = prepare(store, changes.fields)
            publication.journal.changeBatch(publication.fields)
            val saved = checkNotNull(store.record(key))
            for (name in listOf("search", "searchCustom")) {
                assertNull(saved[name]); assertFalse(saved.fields.containsKey(name)); assertFalse(saved.stamps.containsKey(name))
            }
        }
        journal().use { empty ->
            val changes = BrowserSyncCodec.changes(local(), null, emptyList(), "android")
            val publication = prepare(empty, changes.fields)
            publication.journal.changeBatch(publication.fields)
            val made = checkNotNull(empty.record(key))
            assertFalse(made.fields.containsKey("search")); assertFalse(made.fields.containsKey("searchCustom"))
        }
    }

    @Test fun aRemoteClearBetweenLocalProjectionAndPublishCannotResurrectTheOldSelectionOrItsStamps() {
        val original = space()
        journal(original).use { store ->
            val before = BrowserSyncCodec.project(local(), store.all(), "android")
            val changes = BrowserSyncCodec.changes(rename(before), before, store.all(), "android")
            val cleared = original.updated(JsonObject(original.visible.filterKeys { it !in setOf("search", "searchCustom") }), Clock("mac", now = { 200 }))
            store.receive(listOf(VersionedRecord(cleared, 2)))
            val publication = prepare(store, changes.fields)
            publication.journal.changeBatch(publication.fields)
            val saved = checkNotNull(store.record(key))
            assertEquals("Renamed on Android", saved["name"]!!.jsonPrimitive.content)
            for (name in listOf("search", "searchCustom")) {
                assertNull(saved[name]); assertEquals(JsonNull, saved.fields[name]); assertEquals(cleared.stamps[name], saved.stamps[name])
            }
        }
    }

    @Test fun aNewMacSearchValueArrivingAfterTheLocalEditWinsOverTheOldProjectedSpace() {
        val original = space("kagi", "https://latent.invalid/?q=%s")
        journal(original).use { store ->
            val before = BrowserSyncCodec.project(local(), store.all(), "android")
            val changes = BrowserSyncCodec.changes(rename(before), before, store.all(), "android")
            val newer = original.updated(JsonObject(original.visible + mapOf(
                "search" to JsonPrimitive("future-mac-engine"), "searchCustom" to JsonPrimitive("https://new.invalid/search?q=%s"))), Clock("mac", now = { 200 }))
            store.receive(listOf(VersionedRecord(newer, 2)))
            val publication = prepare(store, changes.fields)
            publication.journal.changeBatch(publication.fields)
            val saved = checkNotNull(store.record(key))
            for (name in listOf("search", "searchCustom")) {
                assertEquals(newer[name], saved[name]); assertEquals(newer.stamps[name], saved.stamps[name])
            }
        }
    }

    @Test fun perSpaceMetadataDoesNotInventPhoneSearchRoutingOrReplaceItsGlobalSelection() {
        for ((search, custom) in listOf("kagi" to "https://latent.invalid/?q=%s", "custom" to "javascript:%s", "future-engine" to "opaque")) {
            val settings = BrowserSettings(searchEngine = SearchEngine.CUSTOM, customSearchTemplate = "https://global.invalid/?q=%s")
            val current = BrowserSyncCodec.project(local(settings), listOf(space(search, custom)), "android")
            assertEquals(settings, current.settings)
            assertEquals("https://global.invalid/?q=quiet%20cafes", BrowserAddress.url("quiet cafes", current.settings))
            assertEquals("https://www.google.com/search?q=quiet%20cafes", BrowserAddress.url("quiet cafes",
                BrowserSyncCodec.project(local(), listOf(space(search, custom)), "android").settings))
        }
    }

    @Test fun staleAccountEpochAndRemovedDeviceRefuseBeforeResolvingOrReadingTheJournal() {
        journal(space()).use { store ->
            var accesses = 0
            for ((account, epoch, refused) in listOf(Triple("other", 7L, false), Triple("account", 8L, false), Triple("account", 7L, true))) {
                assertThrows(IllegalStateException::class.java) {
                    BrowserSyncPublication.prepare(mapOf(key to buildJsonObject { put("name", "Wrong owner") }), emptySet(), "account", 7,
                        { account }, { epoch }, { refused }, { accesses++; store })
                }
            }
            assertEquals(0, accesses); assertTrue(store.pending().isEmpty())
            assertEquals("Personal", store.record(key)!!["name"]!!.jsonPrimitive.content)
        }
    }

    @Test fun guardAndCollectionOrderingAndExplicitOneFieldClearKeepTheExistingPublicationContract() {
        val calls = mutableListOf<String>()
        val result = BrowserSyncPublication.prepare(emptyMap(), emptySet(), "account", 7,
            { calls += "account"; "account" }, { calls += "epoch"; 7 }, { calls += "refused"; false }, { calls += "journal"; null })
        assertNull(result); assertEquals(listOf("account", "epoch", "refused", "journal"), calls)
        journal(space()).use { store ->
            var reads = 0
            val observed = object : Journal by store { override fun record(key: RecordKey): Record? { reads++; return store.record(key) } }
            assertThrows(IllegalArgumentException::class.java) {
                prepare(observed, mapOf(RecordKey("chat", "not-browser") to buildJsonObject { put("name", "Wrong collection") }))
            }
            assertEquals(0, reads)
            val before = checkNotNull(store.record(key))
            val publication = prepare(store, mapOf(key to buildJsonObject { put("search", JsonNull) }))
            publication.journal.changeBatch(publication.fields)
            val after = checkNotNull(store.record(key))
            assertNull(after["search"]); assertEquals(JsonNull, after.fields["search"])
            assertEquals(before["searchCustom"], after["searchCustom"]); assertEquals(before.stamps["searchCustom"], after.stamps["searchCustom"])
        }
    }

    @Test fun existingRecordCasStillRejectsAChangedSourceAfterPreparationBeforeAnyWrite() {
        val original = space()
        journal(original).use { store ->
            val publication = prepare(store, mapOf(key to buildJsonObject { put("name", "Pending rename") }))
            val newer = original.updated(JsonObject(original.visible + ("search" to JsonPrimitive("brave"))), Clock("mac", now = { 200 }))
            store.receive(listOf(VersionedRecord(newer, 2)))
            assertThrows(IllegalArgumentException::class.java) { publication.journal.changeBatch(publication.fields, mapOf(key to original)) }
            assertEquals(newer, store.record(key)); assertTrue(store.pending().isEmpty())
        }
    }
}

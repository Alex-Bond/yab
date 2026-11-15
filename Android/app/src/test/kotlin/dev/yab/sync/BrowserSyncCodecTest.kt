package dev.yab.sync

import dev.yab.browser.model.*
import dev.yab.core.sync.Clock
import dev.yab.core.sync.MemoryJournal
import dev.yab.core.sync.Record
import dev.yab.core.sync.RecordKey
import dev.yab.core.sync.Stamp
import dev.yab.core.sync.VersionedRecord
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class BrowserSyncCodecTest {
    private val space = "00000000-0000-0000-0000-000000000001"
    private fun record(kind: String, id: String, fields: JsonObjectBuilder.() -> Unit) = Record(kind, id, buildJsonObject(fields))
    private fun snapshot(tabs: List<BrowserTab>, folders: List<BrowserFolder> = emptyList()) = BrowserSnapshot(
        spaces = listOf(BrowserSpace(space, "Personal", tabs = tabs, currentTabId = tabs.firstOrNull()?.id, folders = folders)), selectedSpaceId = space)
    private fun tab(id: String, place: TabPlace = TabPlace.TODAY, url: String = "https://site.test") = BrowserTab(id, url, "Page", place, createdAt = 1_700_000_000_000)
    private val spaceRecord = record("space", space) { put("name", "Mac space"); put("icon", ""); put("order", "V") }
    @Test fun existingMixedWireOrderIsOnlyProjectedAndNeverPublishedAsANewField() {
        val records = listOf(spaceRecord,
            record("folder", "folder") { put("parent", space); put("name", "Research"); put("order", "B") },
            record("tab", "before") { put("parent", space); put("url", "https://before.test"); put("kept", true); put("order", "A") },
            record("tab", "inside") { put("parent", space); put("url", "https://inside.test"); put("kept", true); put("folder", "folder"); put("order", "C") },
            record("tab", "after") { put("parent", space); put("url", "https://after.test"); put("kept", true); put("order", "D") })
        val received = BrowserSyncCodec.project(snapshot(emptyList()), records, "android")
        val s = received.spaces.single()
        assertEquals(listOf("tab:before", "folder:folder", "tab:inside", "tab:after"), BrowserKeptTree.rows(s).map { it.key })
        val folded = received.copy(spaces = listOf(s.copy(folders = s.folders.map { it.copy(open = false) })))
        val changes = BrowserSyncCodec.changes(folded, received, records, "android")
        assertTrue(changes.fields.isEmpty()); assertTrue(changes.removed.isEmpty())
        assertEquals(s.keptOrder, BrowserSyncCodec.project(folded, records.reversed(), "android").spaces.single().keptOrder)
    }
    @Test fun todayIsOwnedButKeptAndPinnedAreSharedAcrossDevices() {
        val records = listOf(spaceRecord,
            record("tab", "mac-today") { put("parent", space); put("device", "mac"); put("url", "https://mac.test") },
            record("tab", "legacy-today") { put("parent", space); put("url", "https://legacy.test") },
            record("tab", "android-today") { put("parent", space); put("device", "android"); put("url", "https://android.test") },
            record("tab", "kept") { put("parent", space); put("kept", true); put("url", "https://kept.test"); put("home", "https://kept.test") },
            record("tab", "pin") { put("parent", space); put("pin", "K"); put("url", "https://pin.test") })
        val projected = BrowserSyncCodec.project(snapshot(emptyList()), records, "android")
        assertEquals(setOf("android-today", "kept", "pin"), projected.spaces.single().tabs.map { it.id }.toSet())
        assertEquals("Mac space", projected.spaces.single().name)
    }
    @Test fun keptNavigationAndLocalFolderFoldNeverRewriteMacHomeOrFolderState() {
        val kept = tab("kept", TabPlace.KEPT); val folder = BrowserFolder("folder", "Research", open = true)
        val before = snapshot(listOf(kept), listOf(folder))
        val after = snapshot(listOf(kept.copy(url = "https://elsewhere.test", title = "Elsewhere")), listOf(folder.copy(open = false)))
        val records = listOf(spaceRecord,
            record("tab", "kept") { put("parent", space); put("kept", true); put("url", kept.url); put("home", kept.url); put("homeTitle", "Keep home"); put("depth", 0.8) },
            record("folder", "folder") { put("parent", space); put("name", "Research"); put("open", true) })
        val changes = BrowserSyncCodec.changes(after, before, records, "android")
        assertTrue(changes.fields.isEmpty()); assertTrue(changes.removed.isEmpty())
        val imported = BrowserSyncCodec.project(after, records, "android")
        assertEquals("https://elsewhere.test", imported.spaces.single().tabs.single().url)
        assertFalse(imported.spaces.single().folders.single().open)
    }
    @Test fun missingRemoteTodayCannotBeRemovedByLocalDiff() {
        val own = tab("own"); val records = listOf(spaceRecord,
            record("tab", "own") { put("parent", space); put("device", "android"); put("url", own.url) },
            record("tab", "mac") { put("parent", space); put("device", "mac"); put("url", "https://mac.test") })
        val changes = BrowserSyncCodec.changes(snapshot(emptyList()), snapshot(listOf(own)), records, "android")
        assertEquals(setOf(RecordKey("tab", "own")), changes.removed)
        assertFalse(changes.removed.contains(RecordKey("tab", "mac")))
    }
    @Test fun undoCreatesNewIdentityInsteadOfResurrectingRemovalWinsTombstone() {
        val closed = tab("closed")
        val dead = Record("tab", "closed", deleted = Stamp(1, device = "android"))
        val current = snapshot(listOf(closed)).let { it.copy(spaces = it.spaces.map { space -> space.copy(keptOrder = listOf("folder:f", "tab:closed")) }) }
        val revived = BrowserSyncCodec.restoreClosedIds(current, snapshot(emptyList()), listOf(dead))
        assertNotEquals("closed", revived.spaces.single().tabs.single().id)
        assertEquals(closed.url, revived.spaces.single().tabs.single().url)
        assertEquals(listOf("folder:f", "tab:${revived.spaces.single().tabs.single().id}"), revived.spaces.single().keptOrder)
    }
    @Test fun privateSnapshotsAreRejectedBeforeAnyWireWrite() {
        val privateSnapshot = snapshot(listOf(tab("p").copy(isPrivate = true)))
        assertThrows(IllegalArgumentException::class.java) { BrowserSyncCodec.changes(privateSnapshot, null, emptyList(), "android") }
    }
    @Test fun displayingAMacSymbolAndSavingOtherMetadataDoesNotTurnItsWireIconIntoAnEmoji() {
        for (symbol in listOf("star.fill", "future.mac.symbol")) {
            val records = listOf(record("space", space) { put("name", "Mac space"); put("icon", symbol); put("order", "V") })
            val before = BrowserSyncCodec.project(snapshot(emptyList()), records, "android")
            val original = before.spaces.single()
            assertEquals(symbol, original.emoji)
            val displayed = SpaceSymbols.emoji(original.emoji)
            val saved = original.copy(name = "Renamed on Android", emoji = SpaceSymbols.wire(displayed, original.emoji))
            val metadata = BrowserSyncCodec.changes(before.copy(spaces = listOf(saved)), before, records, "android")
            val patch = checkNotNull(metadata.fields[RecordKey("space", space)])
            assertEquals("Renamed on Android", patch["name"]!!.jsonPrimitive.content)
            assertFalse("A metadata save must preserve the exact original Mac symbol", patch.containsKey("icon"))
            val edited = saved.copy(emoji = SpaceSymbols.wire("🎨", original.emoji))
            val changed = BrowserSyncCodec.changes(before.copy(spaces = listOf(edited)), before, records, "android")
            assertEquals("🎨", changed.fields[RecordKey("space", space)]!!["icon"]!!.jsonPrimitive.content)
        }
    }

    @Test fun anExistingIconChangePublishesOneChoiceTupleAndOtherEditsLeaveItsStampAlone() {
        val key = RecordKey("space", space)
        val original = Record("space", space).updated(buildJsonObject {
            put("name", "Work"); put("icon", "star.fill"); put("order", "V")
            put("iconChoice", "star.fill"); put("iconChoiceID", "mac-choice")
            put("future", buildJsonObject { put("nested", JsonNull) })
        }, Clock("mac", now = { 100 }))
        MemoryJournal("android", now = { 1_000 }).use { store ->
            store.receive(listOf(VersionedRecord(original, 1)))
            val before = BrowserSyncCodec.project(snapshot(emptyList()), store.all(), "android")
            val after = before.copy(spaces = before.spaces.map { it.copy(emoji = SpaceSymbols.wire("🎨", it.emoji)) })
            val change = BrowserSyncCodec.changes(after, before, store.all(), "android")
            val patch = checkNotNull(change.fields[key])
            assertEquals(JsonPrimitive("🎨"), patch["icon"]); assertEquals(patch["icon"], patch["iconChoice"])
            val choiceID = UUID.fromString(patch.getValue("iconChoiceID").jsonPrimitive.content).toString()
            assertNotEquals("mac-choice", choiceID)
            publish(store, change)
            val picked = checkNotNull(store.record(key))
            assertEquals(JsonPrimitive(choiceID), picked["iconChoiceID"])
            assertEquals(picked.stamps["icon"], picked.stamps["iconChoice"])
            assertEquals(picked.stamps["icon"], picked.stamps["iconChoiceID"])
            assertTrue(picked.stamps.getValue("icon") > original.stamps.getValue("icon"))
            assertEquals(original["future"], picked["future"]); assertEquals(original.stamps["future"], picked.stamps["future"])

            val seen = BrowserSyncCodec.project(after, store.all(), "android")
            val renamedAndPainted = seen.copy(spaces = seen.spaces.map {
                val look = BrowserSpaceLook.from(it.look, it.color).grain(.6)
                it.copy(name = "Renamed", look = look.raw, color = look.primary)
            })
            val metadata = BrowserSyncCodec.changes(renamedAndPainted, seen, store.all(), "android")
            assertFalse(checkNotNull(metadata.fields[key]).keys.any { it in setOf("icon", "iconChoice", "iconChoiceID") })
            publish(store, metadata)
            val saved = checkNotNull(store.record(key))
            for (field in listOf("icon", "iconChoice", "iconChoiceID")) {
                assertEquals(picked[field], saved[field]); assertEquals(picked.stamps[field], saved.stamps[field])
            }
        }
    }

    @Test fun aNewSpaceAndARepeatedUnchangedPhoneWireIconDoNotInventChoiceFields() {
        val original = Record("space", space).updated(buildJsonObject {
            put("name", "Work"); put("icon", "star.fill"); put("order", "V")
        }, Clock("mac", now = { 100 }))
        MemoryJournal("android", now = { 1_000 }).use { store ->
            store.receive(listOf(VersionedRecord(original, 1)))
            val before = BrowserSyncCodec.project(snapshot(emptyList()), store.all(), "android")
            val repeated = before.copy(spaces = before.spaces.map {
                it.copy(name = "Renamed", emoji = SpaceSymbols.wire(SpaceSymbols.emoji(it.emoji), it.emoji))
            })
            val changes = BrowserSyncCodec.changes(repeated, before, store.all(), "android")
            assertFalse(checkNotNull(changes.fields[original.key]).keys.any { it in setOf("icon", "iconChoice", "iconChoiceID") })
            publish(store, changes)
            val saved = checkNotNull(store.record(original.key))
            assertEquals(original["icon"], saved["icon"]); assertEquals(original.stamps["icon"], saved.stamps["icon"])
            assertNull(saved["iconChoice"]); assertNull(saved["iconChoiceID"])
            assertEquals(original.stamps["iconChoice"], saved.stamps["iconChoice"])
            assertEquals(original.stamps["iconChoiceID"], saved.stamps["iconChoiceID"])
        }
        val fresh = BrowserSyncCodec.changes(snapshot(emptyList()), null, emptyList(), "android")
        val patch = checkNotNull(fresh.fields[original.key])
        assertTrue(patch.containsKey("icon")); assertFalse(patch.containsKey("iconChoice")); assertFalse(patch.containsKey("iconChoiceID"))
    }

    @Test fun aMetadataWritePreservesTheLatestReceivedChoiceRatherThanAnOlderProjection() {
        val key = RecordKey("space", space)
        val original = Record("space", space).updated(buildJsonObject {
            put("name", "Work"); put("icon", "star.fill"); put("order", "V")
            put("iconChoice", "star.fill"); put("iconChoiceID", "first")
        }, Clock("mac", now = { 100 }))
        MemoryJournal("android", now = { 1_000 }).use { store ->
            store.receive(listOf(VersionedRecord(original, 1)))
            val before = BrowserSyncCodec.project(snapshot(emptyList()), store.all(), "android")
            val renamed = before.copy(spaces = before.spaces.map { it.copy(name = "Renamed") })
            val change = BrowserSyncCodec.changes(renamed, before, store.all(), "android")
            val fresh = original.updated(JsonObject(original.visible + mapOf("iconChoiceID" to JsonPrimitive("latest"),
                "unknownChoiceMetadata" to buildJsonObject { put("version", 7) })), Clock("mac", now = { 200 }))
            store.receive(listOf(VersionedRecord(fresh, 2)))
            publish(store, change)
            val saved = checkNotNull(store.record(key))
            for (field in listOf("icon", "iconChoice", "iconChoiceID", "unknownChoiceMetadata")) {
                assertEquals(fresh[field], saved[field]); assertEquals(fresh.stamps[field], saved.stamps[field])
            }
            assertEquals(JsonPrimitive("Renamed"), saved["name"])
        }
    }

    @Test fun aReceivedSameIconOrItsMacSymbolTwinDoesNotRenewALocalPendingChoice() {
        for ((shown, currentWire) in listOf("🎨" to "🎨", "⭐️" to "star.fill")) {
            val original = Record("space", space).updated(buildJsonObject {
                put("name", "Work"); put("icon", "🏠"); put("order", "V")
            }, Clock("mac", now = { 100 }))
            MemoryJournal("android", now = { 1_000 }).use { store ->
                store.receive(listOf(VersionedRecord(original, 1)))
                val before = BrowserSyncCodec.project(snapshot(emptyList()), store.all(), "android")
                val pending = before.copy(spaces = before.spaces.map { it.copy(name = "Renamed", emoji = shown) })
                val received = original.updated(JsonObject(original.visible + mapOf(
                    "icon" to JsonPrimitive(currentWire), "iconChoice" to JsonPrimitive(currentWire),
                    "iconChoiceID" to JsonPrimitive("received-choice"))), Clock("mac", now = { 200 }))
                store.receive(listOf(VersionedRecord(received, 2)))
                val change = BrowserSyncCodec.changes(pending, before, store.all(), "android")
                val patch = checkNotNull(change.fields[original.key])
                assertEquals(JsonPrimitive("Renamed"), patch["name"])
                assertFalse(patch.keys.any { it in setOf("icon", "iconChoice", "iconChoiceID") })
                publish(store, change)
                val saved = checkNotNull(store.record(original.key))
                for (field in listOf("icon", "iconChoice", "iconChoiceID")) {
                    assertEquals(received[field], saved[field]); assertEquals(received.stamps[field], saved.stamps[field])
                }
                val projected = BrowserSyncCodec.project(pending, store.all(), "android")
                assertEquals(currentWire, projected.spaces.single().emoji)
            }
        }
    }

    private fun publish(store: MemoryJournal, changes: BrowserSyncCodec.Changes) {
        checkNotNull(BrowserSyncPublication.publish(changes.fields, changes.removed, "account", 7,
            { "account" }, { 7 }, { false }, { store }, changes.paintEdits) {
            it.journal.changeBatch(it.fields)
        })
    }
}

package dev.yab.core

import dev.yab.core.sync.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ProjectShapesTest {
    private fun record(id: String = "prj-one", fields: JsonObjectBuilder.() -> Unit = {}) = Record("project", id,
        buildJsonObject { put("name", "Work"); fields() })
    private fun project(id: String, pinned: Boolean = false, order: String = "", updated: Double = 0.0, archived: Boolean = false) =
        record(id) { put("pinned", pinned); put("order", order); put("updated", updated); put("archived", archived) }

    @Test fun legacyProjectRecordUsesSyncKitDefaultsWithoutInventingAnOwner() {
        val value = checkNotNull(SyncProject.read(record { put("created", 5) }))
        assertEquals("prj-one", value.id); assertEquals("Work", value.name)
        assertEquals("", value.emoji); assertEquals("blue", value.tint); assertEquals("", value.instructions)
        assertTrue(value.memoryOn); assertFalse(value.pinned); assertFalse(value.archived)
        assertEquals("", value.order); assertEquals(5.0, value.created, 0.0); assertEquals(5.0, value.updated, 0.0)
        assertEquals(value, SyncProject.read(Record.fromJson(record { put("created", 5) }.toJson())))
    }

    @Test fun malformedRequiredIdentityAndNameTypesCannotBecomeProjects() {
        assertNull(SyncProject.read(record().copy(collection = "chat")))
        for (id in listOf("", "prj-", "not-a-project", "prj-a/b")) assertNull(SyncProject.read(record(id)))
        assertNull(SyncProject.read(Record("project", "prj-one")))
        for (name in listOf<JsonElement>(JsonPrimitive(4), JsonPrimitive(true), JsonNull, JsonArray(emptyList()), buildJsonObject {})) {
            assertNull(SyncProject.read(record { put("name", name) }))
        }
        assertEquals("", SyncProject.read(record { put("name", "") })?.name)
    }

    @Test fun optionalTypesUseDefaultsAndOnlyAnActualFalseDisablesMemory() {
        val value = checkNotNull(SyncProject.read(record {
            put("emoji", 1); put("tint", false); put("instructions", JsonArray(emptyList())); put("order", JsonNull)
            put("memoryOn", "false"); put("pinned", "true"); put("archived", 1); put("created", "12"); put("updated", "13")
        }))
        assertEquals("", value.emoji); assertEquals("blue", value.tint); assertEquals("", value.instructions); assertEquals("", value.order)
        assertTrue(value.memoryOn); assertFalse(value.pinned); assertFalse(value.archived)
        assertEquals(0.0, value.created, 0.0); assertEquals(0.0, value.updated, 0.0)
        val exact = checkNotNull(SyncProject.read(record { put("memoryOn", false); put("pinned", true); put("archived", true) }))
        assertFalse(exact.memoryOn); assertTrue(exact.pinned); assertTrue(exact.archived)
    }

    @Test fun fieldsKeepTheExactWireNamesAndNullFalseFlags() {
        val value = SyncProject("prj-one", "Work", "W", "teal", "Be concise.", false, false, true, "a", 5.0, 8.0)
        val expected = Json.parseToJsonElement("""{"name":"Work","emoji":"W","tint":"teal","instructions":"Be concise.","memoryOn":false,"pinned":null,"archived":true,"order":"a","created":5.0,"updated":8.0}""").jsonObject
        assertEquals(expected, value.fields)
        assertEquals(JsonNull, value.copy(archived = false).fields["archived"])
        val written = Record("project", value.id).updated(value.fields, Clock("phone", now = { 100 }))
        assertNull(written["pinned"]); assertEquals(JsonPrimitive(true), written["archived"])
        assertEquals(value, SyncProject.read(written))
    }

    @Test fun fieldPrefixesKeepWholeSwiftCharactersAtAllThreeBounds() {
        val accent = "e\u0301"
        val family = "\uD83D\uDC69\u200D\uD83D\uDC69\u200D\uD83D\uDC67\u200D\uD83D\uDC66"
        val flag = "\uD83C\uDDE8\uD83C\uDDE6"
        val value = SyncProject("prj-one", accent.repeat(201), family.repeat(17), "custom", flag.repeat(8001),
            order = "", created = 0.0, updated = 0.0)
        assertEquals(accent.repeat(200), value.fields["name"]?.jsonPrimitive?.content)
        assertEquals(family.repeat(16), value.fields["emoji"]?.jsonPrimitive?.content)
        assertEquals(flag.repeat(8000), value.fields["instructions"]?.jsonPrimitive?.content)
        assertEquals("custom", value.fields["tint"]?.jsonPrimitive?.content)
        assertEquals(accent.repeat(201), value.name)
    }

    @Test fun projectIdBoundsCountGraphemesWithoutInventingExtraRestrictions() {
        val family = "\uD83D\uDC69\u200D\uD83D\uDC69\u200D\uD83D\uDC67\u200D\uD83D\uDC66"
        for (id in listOf(null, "", "prj-", "PRJ-a", "prj-a/b", "prj-\u0301")) assertFalse(ChatProjects.valid(id))
        assertTrue(ChatProjects.valid("prj-a"))
        assertTrue(ChatProjects.valid("prj-" + family.repeat(36)))
        assertFalse(ChatProjects.valid("prj-" + family.repeat(37)))
        assertTrue(ChatProjects.valid("prj-a\\b"))
    }

    @Test fun ordinaryProjectDeletionAndNewerDeviceResurrectionKeepGenericMergeSemantics() {
        val original = Record("project", "prj-one").updated(buildJsonObject { put("name", "Phone project") }, Clock("phone", now = { 100 }))
        assertEquals("Phone project", SyncProject.read(original)?.name)
        val removed = original.removed(Stamp(150, device = "tablet"))
        assertNull(SyncProject.read(removed)); assertTrue(SyncProject.all(listOf(removed)).isEmpty())
        val restored = removed.updated(buildJsonObject { put("name", "Restored") }, Clock("another-device", now = { 200 }))
        assertEquals("Restored", SyncProject.read(restored)?.name)
        assertEquals("another-device", restored.stamps["name"]?.device)
        assertEquals(SyncProject.read(restored), SyncProject.read(Record.fromJson(restored.toJson())))
    }

    @Test fun pinnedOrderAndIdUseCanonicalSwiftComparisonBeforeUpdatedRows() {
        val bmp = "prj-\uE000"; val supplementary = "prj-\uD800\uDC00"
        val rows = listOf(project("prj-new", updated = 30.0), project("prj-b", true, "e\u0301"),
            project(supplementary, true, "a"), project("prj-old", updated = 2.0),
            project("prj-a", true, "\u00e9"), project(bmp, true, "a"))
        assertEquals(listOf(bmp, supplementary, "prj-a", "prj-b", "prj-new", "prj-old"), SyncProject.all(rows).map { it.id })
    }

    @Test fun unpinnedUpdatedTiesStayStableAndArchivedProjectsRemainReadable() {
        val rows = listOf(project("prj-z", updated = 4.0), record("invalid"), project("prj-a", updated = 4.0),
            project("prj-archived", updated = 5.0, archived = true))
        val values = SyncProject.all(rows)
        assertEquals(listOf("prj-archived", "prj-z", "prj-a"), values.map { it.id })
        assertTrue(values.first().archived)
    }

    @Test fun capabilityNeedsExactLiveSelfWrittenVersionOneFields() {
        assertEquals(1, ChatProjects.VERSION); assertEquals("chatProjects", ChatProjects.FIELD)
        assertEquals("That project isn't on this Mac any more.", ChatProjects.MISSING)
        val cap = Record("commandcap", "mac").updated(buildJsonObject { put("device", "mac"); put("chatProjects", 1) }, Clock("mac", now = { 100 }))
        assertTrue(ChatProjects.supports(cap, "mac")); assertFalse(ChatProjects.supports(null, "mac"))
        assertFalse(ChatProjects.supports(cap.copy(collection = "project"), "mac"))
        assertFalse(ChatProjects.supports(cap.copy(id = "other"), "mac"))
        assertFalse(ChatProjects.supports(cap.copy(schema = 2), "mac"))
        assertFalse(ChatProjects.supports(cap.copy(fields = JsonObject(cap.fields + ("device" to JsonPrimitive("other")))), "mac"))
        for (field in listOf("device", "chatProjects")) {
            assertFalse(ChatProjects.supports(cap.copy(stamps = cap.stamps + (field to Stamp(200, device = "foreign"))), "mac"))
        }
        for (version in listOf<JsonElement>(JsonPrimitive("1"), JsonPrimitive(true), JsonPrimitive(1.1), JsonPrimitive(2), JsonNull, JsonArray(emptyList()))) {
            assertFalse(ChatProjects.supports(cap.copy(fields = JsonObject(cap.fields + ("chatProjects" to version))), "mac"))
        }
        val removed = cap.removed(Stamp(200, device = "mac"))
        assertFalse(ChatProjects.supports(removed, "mac"))
        val restored = removed.updated(buildJsonObject { put("device", "mac"); put("chatProjects", 1.0) }, Clock("mac", now = { 300 }))
        assertTrue(ChatProjects.supports(restored, "mac"))
    }
}

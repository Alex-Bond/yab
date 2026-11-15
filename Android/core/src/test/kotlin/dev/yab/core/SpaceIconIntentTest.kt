package dev.yab.core

import dev.yab.core.sync.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SpaceIconIntentTest {
    @Test fun aNewerLegacyIconOnlyEchoCannotInheritAnOldMatchingChoice() {
        val first = Stamp(100, device = "new-mac")
        val later = Stamp(200, device = "old-mac")
        val picked = Record("space", "work", buildJsonObject {
            put("name", "Work"); put("icon", "⭐️"); put("iconChoice", "⭐️"); put("iconChoiceID", "old-choice")
            put("future", buildJsonObject { put("nested", JsonNull) })
        }, listOf("name", "icon", "iconChoice", "iconChoiceID", "future").associateWith { first })
        val echo = Record("space", "work", buildJsonObject { put("icon", "⭐️") }, mapOf("icon" to later))
        val merged = picked.merged(echo)
        assertEquals(merged, echo.merged(picked))
        assertEquals(JsonPrimitive("⭐️"), merged["icon"]); assertEquals(later, merged.stamps["icon"])
        assertNull(merged["iconChoice"]); assertNull(merged["iconChoiceID"])
        assertFalse(merged.stamps.containsKey("iconChoice")); assertFalse(merged.stamps.containsKey("iconChoiceID"))
        assertEquals(picked["name"], merged["name"]); assertEquals(picked["future"], merged["future"])
        assertEquals(merged, Record.parse(merged.toJson().toString()))
    }

    @Test fun aRenewedChoiceIdentityMovesTheWholeGroupWhileAnUnrelatedRenameDoesNot() {
        var current = Record("space", "work").updated(buildJsonObject {
            put("name", "Work"); put("icon", "⭐️"); put("iconChoice", "⭐️"); put("iconChoiceID", "first")
        }, Clock("mac", now = { 100 }))
        // The shared group must also understand a Mac's repeated pick. The Phone writer
        // does not generate these identities when its wire icon stays unchanged.
        for ((number, identity) in listOf("second", "third").withIndex()) {
            val previous = current
            current = current.updated(JsonObject(current.visible + ("iconChoiceID" to JsonPrimitive(identity))),
                Clock("mac", now = { 200L + number }))
            assertEquals(previous["icon"], current["icon"]); assertEquals(previous["iconChoice"], current["iconChoice"])
            assertTrue(current.stamps.getValue("icon") > previous.stamps.getValue("icon"))
            assertEquals(current.stamps["icon"], current.stamps["iconChoice"])
            assertEquals(current.stamps["icon"], current.stamps["iconChoiceID"])
            assertEquals(current, previous.merged(current)); assertEquals(current, current.merged(previous))
        }
        val renamed = current.updated(JsonObject(current.visible + ("name" to JsonPrimitive("Renamed"))), Clock("mac", now = { 400 }))
        for (field in listOf("icon", "iconChoice", "iconChoiceID")) {
            assertEquals(current[field], renamed[field]); assertEquals(current.stamps[field], renamed.stamps[field])
        }
    }
}

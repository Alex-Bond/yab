package dev.yab.sync

import dev.yab.agent.MacAvailability
import dev.yab.agent.MacPhase
import dev.yab.agent.RemoteConnection
import dev.yab.agent.RemoteMac
import dev.yab.core.sync.Clock
import dev.yab.core.sync.Record
import dev.yab.core.sync.Stamp
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class MacTodayTest {
    private val first = RemoteMac("first-mac", "MacBook", true, emptySet(), frontTab = "front")
    private val second = RemoteMac("second-mac", "Mac mini", false, emptySet(), availability = MacAvailability(MacPhase.ASLEEP, 100))
    private val connection = RemoteConnection("account", listOf(first, second))
    private fun tab(id: String, owner: String? = first.id, space: String = "public-space", order: String = "V", extra: JsonObjectBuilder.() -> Unit = {}): Record =
        Record("tab", id).updated(buildJsonObject {
            put("parent", space); owner?.let { put("device", it) }; put("url", "https://example.test/$id"); put("title", "Page $id"); put("order", order); extra()
        }, Clock(owner ?: first.id, now = { 100 }))
    private fun image(vararg records: Record) = AccountRecordsSnapshot("account", 7, records.toList(), phase = "live", device = "android-phone")

    @Test fun genuineOwnerGroupsKeepMacOrderAndFrontLeadsWithinItsOwnOrder() {
        val rows = listOf(tab("later", order = "Z"), tab("front", order = "z"), tab("earlier", order = "A"), tab("other", second.id))
        val groups = MacTodayProjection.groups(image(*rows.toTypedArray()), connection, "public-space")
        assertEquals(listOf(first.id, second.id), groups.map { it.mac.id })
        assertEquals(listOf("front", "earlier", "later"), groups.first().rows.map { it.id })
        assertEquals(listOf(true, false, false), groups.first().rows.map { it.front })
        assertEquals(second.id, groups.last().rows.single().mac)
        assertTrue(groups.flatMap { it.rows }.all { it.account == "account" && it.epoch == 7L && !it.closing })
    }

    @Test fun anExplicitJsonNullUnpinBecomesTodayButALivePinOrKeptRowDoesNot() {
        val originallyPinned = tab("unpinned") { put("pin", "1") }
        val unpinned = originallyPinned.updated(JsonObject(originallyPinned.visible + ("pin" to JsonNull)), Clock(first.id, now = { 101 }))
        val pinned = tab("pinned") { put("pin", "1") }
        val kept = tab("kept") { put("kept", true) }
        val rows = MacTodayProjection.groups(image(unpinned, pinned, kept), connection, "public-space").flatMap { it.rows }
        assertEquals(listOf("unpinned"), rows.map { it.id })
        assertEquals(JsonNull, rows.single().record.fields["pin"])
        assertNull(rows.single().record["pin"])
    }

    @Test fun ownAndroidUnknownAndRevokedOwnersCannotBecomeTheFirstMacsTabs() {
        val known = tab("known", second.id)
        val rows = listOf(known, tab("own", "android-phone"), tab("unknown", "unrecognized-device"), tab("revoked", "revoked-mac"))
        val groups = MacTodayProjection.groups(image(*rows.toTypedArray()), connection, "public-space")
        assertEquals(listOf(second.id), groups.map { it.mac.id }); assertEquals(listOf(known.id), groups.single().rows.map { it.id })
        assertTrue(MacTodayProjection.groups(image(known), connection.copy(macs = listOf(first)), "public-space").isEmpty())
        assertTrue(MacTodayProjection.groups(image(known), connection.copy(macs = emptyList()), "public-space").isEmpty())
    }

    @Test fun legacyUnownedRowsUseARealKnownMacAndFutureOrUnsafeRecordsNeverEnterTheSurface() {
        val legacy = tab("legacy", owner = null) { put("futureField", buildJsonObject { put("keep", "untouched") }) }
        val valid = tab("valid")
        val deleted = tab("deleted").removed(Stamp(101, device = first.id))
        val future = Record.parse(tab("future").toJson().let { JsonObject(it + ("schema" to JsonPrimitive(99))).toString() })
        val rows = listOf(legacy, valid, deleted, future, tab("private-namespace", space = "private-space"),
            tab("script") { put("url", "javascript:alert(1)") }, tab("credentials") { put("url", "https://user:secret@example.test/") },
            tab("missing-url") { put("url", JsonNull) })
        val projected = MacTodayProjection.groups(image(*rows.toTypedArray()), connection, "public-space").single().rows
        assertEquals(setOf("legacy", "valid"), projected.map { it.id }.toSet())
        assertEquals(first.id, projected.first { it.id == "legacy" }.mac)
        assertEquals(legacy, projected.first { it.id == "legacy" }.record)
        assertTrue(MacTodayProjection.groups(image(legacy), connection.copy(macs = emptyList()), "public-space").isEmpty())
    }

    @Test fun accountRemovalAndSpaceChangesCannotBorrowAnotherSnapshot() {
        val source = image(tab("one"))
        assertTrue(MacTodayProjection.groups(source, connection.copy(account = "other-account"), "public-space").isEmpty())
        assertTrue(MacTodayProjection.groups(source.copy(removed = true), connection, "public-space").isEmpty())
        assertTrue(MacTodayProjection.groups(source.copy(account = null), connection, "public-space").isEmpty())
        assertTrue(MacTodayProjection.groups(source, connection, "other-space").isEmpty())
    }

    @Test fun pendingCloseIsShownOnlyForTheSameDownOwnerAndClearsWhenItReturnsOrLeaves() {
        val original = MacTodayProjection.groups(image(tab("down", second.id)), connection, "public-space").single().rows.single()
        val pending = original.copy(closing = true)
        val empty = image()
        assertEquals(listOf(pending), MacTodayProjection.groups(empty, connection, "public-space", listOf(pending)).single().rows)
        val up = connection.copy(macs = listOf(first, second.copy(awake = true, availability = MacAvailability(MacPhase.UP))))
        assertTrue(MacTodayProjection.groups(empty, up, "public-space", listOf(pending)).isEmpty())
        assertTrue(MacTodayProjection.groups(empty.copy(epoch = 8), connection, "public-space", listOf(pending)).isEmpty())
        assertTrue(MacTodayProjection.groups(empty, connection.copy(macs = listOf(first)), "public-space", listOf(pending)).isEmpty())
        assertTrue(MacTodayProjection.groups(empty, connection, "private-space", listOf(pending)).isEmpty())
        val stillLiving = MacTodayProjection.groups(image(original.record), connection, "public-space", listOf(pending)).single().rows
        assertEquals(listOf(original), stillLiving)
    }
}

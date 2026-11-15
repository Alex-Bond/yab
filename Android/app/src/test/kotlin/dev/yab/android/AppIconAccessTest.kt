package dev.yab.android

import dev.yab.core.sync.Clock
import dev.yab.core.sync.Record
import dev.yab.sync.AccountRecordsSnapshot
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

class AppIconAccessTest {
    private val zone = ZoneId.of("Europe/Lisbon")
    private val during = AppIcon.halloweenEnd(zone).minusSeconds(1)
    private class Local(var state: AppIconLocalState = AppIconLocalState()) : AppIconLocalStore {
        var writes = 0
        override fun read() = state
        override fun merge(value: AppIconLocalState): AppIconLocalState { state = state.merged(value); writes++; return state }
    }
    private class Native(var value: AppIconVariant = AppIcon.Flat.variant()) : AppIconNativePort {
        var calls = 0
        var afterChoose: (() -> Unit)? = null
        var refuse = false
        override fun selected() = listOf(value)
        override fun choose(variant: AppIconVariant) { calls++; if (!refuse) value = variant; afterChoose?.invoke() }
    }
    private fun setting(key: String, value: JsonElement) = Record("setting", key).updated(buildJsonObject { put("value", value) }, Clock("mac"))

    @Test fun onlyRealGrantBooleansAndValidGiftReceiptsUnlockRewards() {
        val access = AppIconAccess.fromValues(mapOf(AppIcon.SmokedChrome.grantKey to JsonPrimitive(true),
            AppIcon.Amber.grantKey to JsonPrimitive(false), AppIcon.RedEnamel.grantKey to JsonPrimitive("true"),
            AppIcon.Arcade.grantKey to JsonPrimitive(1), "appearance.appIcon.unlocked.unknown" to JsonPrimitive(true),
            "gift.firstEdition.receipt" to JsonPrimitive("a".repeat(64)), "invite.joined" to JsonPrimitive(100)))
        assertEquals(setOf(AppIcon.SmokedChrome, AppIcon.FirstEdition), access.imported)
        assertFalse(access.unlocked(AppIcon.Ticket, emptySet(), during, zone))
        assertFalse(access.unlocked(AppIcon.RedEnamel, emptySet(), during, zone))
        for (receipt in listOf("", "short", "A".repeat(64), "g".repeat(64)))
            assertTrue(AppIconAccess.fromValues(mapOf("gift.firstEdition.receipt" to JsonPrimitive(receipt))).imported.isEmpty())
        for (value in listOf<JsonElement>(JsonNull, JsonPrimitive(true), JsonPrimitive(123)))
            assertTrue(AppIconAccess.fromValues(mapOf("gift.firstEdition.receipt" to value)).imported.isEmpty())
    }

    @Test fun unearnedArtworkVisibilityMatchesCurrentPhoneInsteadOfGrantingAllAlternates() {
        val access = AppIconAccess()
        for (icon in AppIcon.entries) {
            assertEquals(icon.wireId, !icon.reward || icon.seasonal, access.unlocked(icon, emptySet(), during, zone))
            assertEquals(icon.wireId, !icon.reward || icon.friendCount != null || icon == AppIcon.Charm,
                access.visible(icon, emptySet(), during, zone))
        }
        assertEquals(18, AppIcon.entries.size)
        assertEquals(setOf(1, 3, 7, 10), AppIcon.entries.mapNotNull { it.friendCount }.toSet())
    }

    @Test fun wornSeasonalReadbackPersistsOnlyThatIconAndCrossesTheLocalCalendarEnd() {
        val local = Local(); val native = Native()
        var at = during
        val selection = AppIconSelection(local, native, { at }, { zone })
        selection.migrateLegacy()
        assertTrue(local.state.kept.isEmpty())
        assertEquals(AppIcon.Pumpkin, selection.choose(AppIcon.Pumpkin, AppIconAccess()) { true })
        assertEquals(setOf(AppIcon.Pumpkin), local.state.kept)
        assertNull(selection.choose(AppIcon.Pumpkin, AppIconAccess()) { true })
        at = AppIcon.halloweenEnd(zone)
        assertTrue(AppIconAccess().unlocked(AppIcon.Pumpkin, local.state.kept, at, zone))
        assertFalse(AppIconAccess().unlocked(AppIcon.Ghost, local.state.kept, at, zone))
        assertThrows(IllegalStateException::class.java) { selection.choose(AppIcon.Ghost, AppIconAccess()) { true } }
        assertEquals(1, native.calls)
        val reopened = AppIconSelection(local, native, { at }, { zone })
        assertEquals(setOf(AppIcon.Pumpkin), reopened.migrateLegacy().kept)
        assertEquals(Instant.parse("2026-11-02T15:00:00Z"), AppIcon.halloweenEnd(ZoneId.of("Asia/Tokyo")))
    }

    @Test fun refusedNativeSelectionOrSeasonEndingBeforeReadbackNeverEarnsAnIcon() {
        val local = Local(); val native = Native().apply { refuse = true }
        var at = during
        val selection = AppIconSelection(local, native, { at }, { zone })
        assertThrows(IllegalStateException::class.java) { selection.choose(AppIcon.Ghost, AppIconAccess()) { true } }
        assertTrue(local.state.kept.isEmpty())
        native.refuse = false
        native.afterChoose = { at = AppIcon.halloweenEnd(zone) }
        assertNull(selection.choose(AppIcon.Ghost, AppIconAccess()) { true })
        assertEquals(AppIcon.Ghost.variant(), native.value)
        assertTrue(local.state.kept.isEmpty())
    }

    @Test fun legacyMigrationKeepsOnlyTheInstalledOldRewardOnce() {
        val local = Local(); val native = Native(AppIcon.Amber.variant())
        val selection = AppIconSelection(local, native)
        assertEquals(setOf(AppIcon.Amber), selection.migrateLegacy().kept)
        native.value = AppIcon.RedEnamel.variant()
        assertEquals(setOf(AppIcon.Amber), selection.migrateLegacy().kept)
        assertEquals(1, local.writes); assertEquals(0, native.calls)
        val fresh = Local()
        assertTrue(AppIconSelection(fresh, Native(AppIcon.FirstEdition.variant())).migrateLegacy().kept.isEmpty())
    }

    @Test fun staleOwnerCannotChooseOrPublishWhileACompletedLocalWearStaysLocal() {
        val local = Local(AppIconLocalState(migrated = true)); val native = Native()
        val selection = AppIconSelection(local, native, { during }, { zone })
        var epoch = 1
        assertThrows(IllegalStateException::class.java) { selection.choose(AppIcon.Pumpkin, AppIconAccess()) { epoch == 0 } }
        assertEquals(0, native.calls)
        native.afterChoose = { epoch = 2 }
        assertNull(selection.choose(AppIcon.Pumpkin, AppIconAccess()) { epoch == 1 })
        assertEquals(setOf(AppIcon.Pumpkin), local.state.kept)
        assertEquals(AppIcon.Pumpkin.variant(), native.value)
    }

    @Test fun importedRewardsAndUpdatedCharmColorsNeverBecomeLocalOwnershipOrNativeChanges() {
        val local = Local(AppIconLocalState(migrated = true)); val native = Native()
        val selection = AppIconSelection(local, native, { during }, { zone })
        val first = AppIconAccess.fromValues(mapOf(AppIcon.Charm.grantKey to JsonPrimitive(true),
            "invite.charm.left" to JsonPrimitive("rose"), "invite.charm.right" to JsonPrimitive("sky")))
        assertEquals(0, native.calls)
        assertNull(selection.choose(AppIcon.Charm, first) { true })
        assertEquals(AppIcon.Charm.variant(AppIconCharm.of("rose", "sky")), native.value)
        val updated = AppIconAccess.fromValues(mapOf(AppIcon.Charm.grantKey to JsonPrimitive(true),
            "invite.charm.left" to JsonPrimitive("rose"), "invite.charm.right" to JsonPrimitive("lilac")))
        assertNotEquals(AppIcon.Charm.variant(updated.charm), native.value)
        assertEquals(1, native.calls); assertTrue(local.state.kept.isEmpty())
        assertEquals(AppIconCharm.of("mint", "mint"), AppIconAccess.fromValues(mapOf("invite.charm.left" to JsonPrimitive("unknown"), "invite.charm.right" to JsonPrimitive("silver"))).charm)
        assertEquals(AppIconCharm.DEFAULT, AppIconAccess.fromValues(emptyMap()).charm)
    }

    @Test fun atomicAccountFramesDropRemovedOrDeletedGrantsAndChangeOnSameAccountReconnect() {
        val grant = setting(AppIcon.Ticket.grantKey, JsonPrimitive(true))
        val source = AccountRecordsSnapshot("account-a", 1, listOf(grant), device = "phone")
        val first = AppIconAccountFrame.from(source)
        assertEquals(setOf(AppIcon.Ticket), first.access.imported)
        assertNotEquals(first, AppIconAccountFrame.from(source.copy(epoch = 2)))
        assertTrue(AppIconAccountFrame.from(source.copy(account = "account-b", records = emptyList())).access.imported.isEmpty())
        assertTrue(AppIconAccountFrame.from(source.copy(removed = true)).access.imported.isEmpty())
        assertTrue(AppIconAccountFrame.from(source.copy(records = listOf(grant.removed(grant.stamps.getValue("value").let { it.copy(wall = it.wall + 1) })))).access.imported.isEmpty())
        assertTrue(AppIconAccess.fromRecords(listOf(grant.copy(schema = 2))).imported.isEmpty())
    }

    @Test fun everyCharmPalettePairHasOneCanonicalDistinctRealAlias() {
        val variants = AppIcon.variants
        assertEquals(73, variants.size)
        assertEquals(73, variants.map { it.alias }.toSet().size)
        assertEquals(56, variants.count { it.icon == AppIcon.Charm })
        assertEquals("Charm", AppIcon.Charm.variant().alias)
        assertEquals("Charm_rose_sky", AppIcon.Charm.variant(AppIconCharm.of("rose", "sky")).alias)
        assertEquals("app_icon_charm_rose_sky", AppIcon.Charm.variant(AppIconCharm.of("rose", "sky")).resourceName)
        assertThrows(IllegalArgumentException::class.java) { AppIconVariant(AppIcon.Ticket, AppIconCharm.DEFAULT) }
    }

    @Test fun staleMigrationFromAnotherStoreCannotEraseAnInterleavedConfirmedWear() {
        val durable = Local()
        fun view() = object : AppIconLocalStore {
            override fun read() = durable.read()
            override fun merge(value: AppIconLocalState) = durable.merge(value)
        }
        val worn = Native()
        val choose = AppIconSelection(view(), worn, { during }, { zone })
        var interleaved = false
        val migration = AppIconSelection(view(), object : AppIconNativePort {
            override fun selected(): List<AppIconVariant> {
                if (!interleaved) {
                    interleaved = true
                    assertEquals(AppIcon.Pumpkin, choose.choose(AppIcon.Pumpkin, AppIconAccess()) { true })
                }
                return listOf(AppIcon.Flat.variant())
            }
            override fun choose(variant: AppIconVariant): Unit = error("Migration must never choose an icon")
        })
        assertEquals(setOf(AppIcon.Pumpkin), migration.migrateLegacy().kept)
        assertEquals(setOf(AppIcon.Pumpkin), durable.read().kept)
        assertTrue(durable.read().migrated)
        assertEquals(AppIcon.Pumpkin.variant(), worn.value)
    }
}

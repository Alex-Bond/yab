package dev.yab.sync

import dev.yab.browser.model.*
import dev.yab.core.sync.Clock
import dev.yab.core.sync.Record
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserHistoryTest {
    private val now = 1_800_000_000_000L
    private fun snapshot(history: List<BrowserVisit> = emptyList(), on: Boolean = true) = BrowserSnapshot(
        spaces = listOf(BrowserSpace("space", "Personal")), selectedSpaceId = "space", history = history, settings = BrowserSettings(syncHistory = on))
    private fun visit(at: Double, writer: String = "mac", url: String = "https://example.test/page") = Record("visit", BrowserHistory.key(url)).updated(buildJsonObject {
        put("url", url); put("title", "From Mac"); put("last", at)
    }, Clock(writer))
    private class Engine : BrowserEngine {
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun close(tabId: String) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }

    @Test fun optOutDoesNotDeleteSharedVisitsAndReenableBackfillsOnlyEligibleLocalHistory() {
        val rows = listOf(BrowserVisit("https://example.test/page", "Local", now - 1000),
            BrowserVisit("https://other.test/remote", "Imported", now, syncedKey = "other.test/remote", syncedAt = now / 1000.0),
            BrowserVisit("https://auth.test/?login_hint=me", "Sign in", now),
            BrowserVisit("https://auth.test/?client_id=x&redirect_uri=y", "OAuth", now),
            BrowserVisit("https://auth.test/?code=x&state=y", "Callback", now),
            BrowserVisit("https://user:secret@auth.test/", "Credentials", now),
            BrowserVisit("https://old.test/", "Too old", now - 15L * 86_400_000))
        val off = snapshot(rows, on = false)
        val shared = visit(now / 1000.0, url = "https://other.test/remote")
        val stopped = BrowserSyncCodec.changes(off, off.copy(settings = BrowserSettings()), listOf(shared), "android", now)
        assertTrue(stopped.fields.keys.none { it.collection == "visit" }); assertTrue(stopped.removed.none { it.collection == "visit" })
        val on = off.copy(settings = off.settings.copy(syncHistory = true))
        val backfill = BrowserSyncCodec.changes(on, off, listOf(shared), "android", now)
        assertEquals(setOf("example.test/page"), backfill.fields.keys.filter { it.collection == "visit" }.map { it.id }.toSet())
        val imported = BrowserSyncCodec.project(off, listOf(shared), "android", now = now)
        assertFalse(imported.settings.syncHistory); assertTrue(imported.history.any { it.syncedKey == shared.id })
    }

    @Test fun localAndNewerMacRowsKeepDistinctIdentityAndOwnRecordsNeverReappear() {
        val local = BrowserVisit("https://example.test/page", "Here", now - 200_000)
        val remote = visit((now - 100_000) / 1000.0)
        val projected = BrowserSyncCodec.project(snapshot(listOf(local)), listOf(remote), "android", now = now)
        assertEquals(2, projected.history.size); assertEquals(2, projected.history.map { it.identity }.toSet().size)
        val sameMinute = visit((now - 150_000) / 1000.0)
        assertEquals(listOf(local), BrowserSyncCodec.project(snapshot(listOf(local)), listOf(sameMinute), "android", now = now).history)
        assertTrue(BrowserSyncCodec.project(snapshot(), listOf(visit(now / 1000.0, "android")), "android", now = now).history.isEmpty())
    }

    @Test fun importedDeletePersistsWirePrecisionAndOnlyANewerVisitReturns() = runTest {
        val directory = Files.createTempDirectory("history-delete").toFile()
        try {
            val file = directory.resolve("browser.json"); val disk = FileBrowserRepository(file)
            val local = BrowserVisit("https://example.test/page", "Here", now - 200_000)
            val remote = visit((now - 100_000) / 1000.0 + 0.0002)
            disk.save(snapshot(listOf(local), on = false))
            val loaded = disk.load()!!
            val memory = object : BrowserRepository { override suspend fun load() = loaded; override suspend fun save(snapshot: BrowserSnapshot) {} }
            val current = BrowserController(memory, Engine(), backgroundScope, now = { now }); runCurrent()
            current.applySyncedSnapshot(BrowserSyncCodec.project(loaded, listOf(remote), "android", now = now))
            val imported = current.state.value.history.single { it.syncedKey != null }
            current.deleteVisit(imported)
            assertEquals(listOf(local), current.state.value.history)
            val saved = current.publicSnapshot()!!; disk.save(saved)
            val restored = disk.load()!!
            assertFalse(restored.settings.syncHistory)
            assertTrue(restored.history.none { it.syncedKey != null })
            assertEquals(imported.syncedAt, restored.historyForgetting.places[remote.id])
            assertEquals(listOf(local), BrowserSyncCodec.project(restored, listOf(remote), "android", now = now).history)
            val hiddenAt = checkNotNull(imported.syncedAt)
            val newer = visit(hiddenAt + 0.0001)
            assertTrue(BrowserSyncCodec.project(restored, listOf(newer), "android", now = now).history.any { it.syncedAt == hiddenAt + 0.0001 })
        } finally { directory.deleteRecursively() }
    }

    @Test fun clearAddsInclusiveLocalSpansAndClearDataKeepsTabsAndFutureImportsOutsideTheSpan() = runTest {
        val tab = BrowserTab("tab", "https://kept.test", "Keep", place = TabPlace.KEPT, createdAt = now)
        val state = snapshot(listOf(BrowserVisit("https://here.test", "Here", now))).copy(spaces = listOf(BrowserSpace("space", "Personal", tabs = listOf(tab), currentTabId = tab.id)))
        val memory = object : BrowserRepository { override suspend fun load() = state; override suspend fun save(snapshot: BrowserSnapshot) {} }
        val browser = BrowserController(memory, Engine(), backgroundScope, now = { now }); runCurrent()
        browser.clearHistoryAndData(); runCurrent()
        val cleared = browser.publicSnapshot()!!
        assertEquals(listOf(tab), cleared.spaces.single().tabs); assertTrue(cleared.history.isEmpty())
        val atBoundary = visit(now / 1000.0 + 60)
        assertTrue(BrowserSyncCodec.project(cleared, listOf(atBoundary), "android", now = now).history.isEmpty())
        val after = visit(now / 1000.0 + 60.001)
        assertEquals(1, BrowserSyncCodec.project(cleared, listOf(after), "android", now = now).history.size)
        val combined = HistoryForgetting().clear(1.0, 4.0).clear(3.0, 8.0).clear(8.0, 9.0)
        assertEquals(listOf(HistorySpan(1.0, 9.0)), combined.spans)
    }

    @Test fun oldProfilesDefaultToOnButCheckpointNeverReenablesConsentOrDropsHidesAndPrivateStaysLocal() = runTest {
        val legacy = """{"spaces":[{"id":"space","name":"Personal"}],"selectedSpaceId":"space"}"""
        assertTrue(Json.decodeFromString<BrowserSnapshot>(legacy).settings.syncHistory)
        val off = snapshot(on = false).copy(historyForgetting = HistoryForgetting().forget("example.test", now / 1000.0))
        val memory = object : BrowserRepository { override suspend fun load() = off; override suspend fun save(snapshot: BrowserSnapshot) {} }
        val browser = BrowserController(memory, Engine(), backgroundScope, now = { now }); runCurrent()
        browser.openExternalUrl("https://recorded.test/page")
        browser.pageChanged(browser.state.value.tab!!.id, EnginePageState(url = "https://recorded.test/page", progress = 1f))
        assertEquals(1, browser.publicSnapshot()!!.history.size); assertFalse(browser.publicSnapshot()!!.settings.syncHistory)
        browser.openUrl("https://private.test", privately = true); browser.unlockPrivate(true)
        browser.pageChanged(browser.state.value.tab!!.id, EnginePageState(url = "https://private.test", progress = 1f))
        assertTrue(browser.publicSnapshot()!!.history.none { it.url.contains("private") })
        val target = off.copy(settings = BrowserSettings(syncHistory = true))
        val checkpoint = BrowserSyncCheckpoint(account = "account", device = "android", target = target, knownLocalHashes = listOf(BrowserSnapshotHash.of(off)), localSearch = false)
        assertFalse(checkpoint.restore(off).settings.syncHistory)
        assertEquals(off.historyForgetting, checkpoint.restore(off).historyForgetting)
    }

    @Test fun preHistoryControlCheckpointHashStillRecoversAnInterruptedSnapshot() {
        // Exact pre-control encodeDefaults shape, independently retained as a format fixture.
        val old = """{"schema":1,"spaces":[{"id":"space","name":"Personal","emoji":"","color":4293847522,"ownSignIns":false,"isPrivate":false,"tabs":[],"currentTabId":null,"folders":[]}],"selectedSpaceId":"space","history":[],"settings":{"appearance":"SYSTEM","searchEngine":"GOOGLE","customSearchTemplate":"","blocksAds":true,"darkenWebsites":false,"autoClearToday":false,"lockPrivate":true,"welcomed":false},"recency":{}}"""
        val before = Json.decodeFromString<BrowserSnapshot>(old)
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(old.toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
        assertTrue(BrowserSnapshotHash.compatible(before).contains(hash))
        val target = before.copy(spaces = listOf(before.spaces.single().copy(name = "Committed from Mac")))
        val checkpoint = BrowserSyncCheckpoint(account = "account", device = "android", target = target, knownLocalHashes = listOf(hash), localSearch = false)
        assertEquals(target, checkpoint.restore(before))
        assertFalse(checkpoint.restore(before.copy(settings = before.settings.copy(syncHistory = false))).settings.syncHistory)
    }

    @Test fun exactPreSwipeCheckpointRecoversButCannotOverwriteAnExplicitOffToggle() {
        // A separate retained encodeDefaults shape, including then-existing consent fields.
        val old = """{"schema":1,"spaces":[{"id":"space","name":"Personal","emoji":"","color":4293847522,"ownSignIns":false,"isPrivate":false,"tabs":[],"currentTabId":null,"folders":[]}],"selectedSpaceId":"space","history":[],"settings":{"appearance":"SYSTEM","searchEngine":"GOOGLE","customSearchTemplate":"","blocksAds":true,"darkenWebsites":false,"autoClearToday":false,"lockPrivate":true,"welcomed":false,"syncHistory":true,"macTabs":false},"recency":{},"historyForgetting":{"places":{},"spans":[]}}"""
        val before = Json.decodeFromString<BrowserSnapshot>(old)
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(old.toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
        assertTrue(BrowserSnapshotHash.compatible(before).contains(hash))
        val target = before.copy(spaces = listOf(before.spaces.single().copy(name = "Committed from Mac")))
        val checkpoint = BrowserSyncCheckpoint(account = "account", device = "android", target = target,
            knownLocalHashes = listOf(hash), localSearch = false)
        assertEquals(target, checkpoint.restore(before))
        val edited = before.copy(settings = before.settings.copy(swipeAnywhere = false))
        assertFalse(BrowserSnapshotHash.compatible(edited).contains(hash))
        assertEquals(edited, checkpoint.restore(edited))
    }
}

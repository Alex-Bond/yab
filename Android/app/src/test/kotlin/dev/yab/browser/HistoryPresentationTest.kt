package dev.yab.browser

import dev.yab.browser.model.*
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HistoryPresentationTest {
    private val now = Instant.parse("2026-03-09T18:00:00Z").toEpochMilli()
    private val visit = BrowserVisit("https://www.example.test/article?q=one#part", "A saved article", now - 1_000)
    private fun snapshot(front: BrowserTab = BrowserTab("front", createdAt = now), history: List<BrowserVisit> = listOf(visit)) =
        BrowserSnapshot(spaces = listOf(BrowserSpace("public", "Personal", tabs = listOf(front), currentTabId = front.id)), selectedSpaceId = "public", history = history)
    private class Repo(val snapshot: BrowserSnapshot) : BrowserRepository {
        override suspend fun load() = snapshot
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }
    private class Engine : BrowserEngine {
        val navigated = mutableListOf<Pair<BrowserTab, WebsiteProfile>>()
        val activated = mutableListOf<Pair<BrowserTab, WebsiteProfile>>()
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) { activated += tab to profile }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { navigated += tab to profile }
        override fun close(tabId: String) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }

    @Test fun searchRequiresEveryWordAcrossTitleAndAddressIgnoringAccentCaseAndWidth() {
        val cafe = visit.copy(title = "Café Design", url = "https://www.example.test/Guides?lang=fr")
        val other = visit.copy(title = "Other", url = "https://another.test/")
        assertEquals(listOf(cafe), HistoryPresentation.matching(listOf(cafe, other), "ＧＵＩＤＥＳ cafe"))
        assertEquals(listOf(cafe), HistoryPresentation.matching(listOf(cafe, other), "design\u00a0EXAMPLE"))
        assertTrue(HistoryPresentation.matching(listOf(cafe), "cafe missing").isEmpty())
        assertEquals("example.test:8443/article?q=one#part", HistoryPresentation.pretty("https://www.example.test:8443/article?q=one#part"))
        assertEquals("example.test", HistoryPresentation.pretty("http://www.example.test/"))
    }

    @Test fun daysClampFutureClockAndUseLocalCalendarAcrossSpringDST() {
        val zone = ZoneId.of("America/Los_Angeles")
        val yesterday = visit.copy(url = "https://yesterday.test", visitedAt = Instant.parse("2026-03-09T06:59:00Z").toEpochMilli())
        val future = visit.copy(url = "https://future.test", visitedAt = now + 5 * 86_400_000L)
        val days = HistoryPresentation.days(listOf(yesterday, visit, future), now, zone)
        assertEquals(listOf(LocalDate.of(2026, 3, 9), LocalDate.of(2026, 3, 8)), days.map { it.date })
        assertEquals(listOf(future, visit), days.first().visits)
        assertEquals(listOf(yesterday), days.last().visits)
        val todayStart = HistoryRange.TODAY.start(now, zone)
        val yesterdayStart = HistoryRange.TODAY_AND_YESTERDAY.start(now, zone)
        assertEquals(Instant.parse("2026-03-08T08:00:00Z").toEpochMilli(), yesterdayStart)
        assertEquals(23 * 3_600_000L, todayStart - yesterdayStart)
    }

    @Test fun openingHistoryFromPrivateAlwaysCreatesOrdinaryPageAndKeepsPrivateAndBlankTabs() = runTest {
        val engine = Engine()
        val browser = BrowserController(Repo(snapshot()), engine, backgroundScope, now = { now })
        runCurrent()
        browser.openUrl("https://private.test/secret", privately = true)
        browser.unlockPrivate(true)
        val privateTab = browser.state.value.tab!!
        browser.show(BrowserSurface.HISTORY)
        engine.navigated.clear()
        assertTrue(browser.openHistoryVisit(browser.captureHistoryPresentation()!!, visit))
        val current = browser.state.value
        assertEquals(BrowserSurface.PAGE, current.surface)
        assertFalse(current.space!!.isPrivate)
        assertFalse(current.tab!!.isPrivate)
        assertEquals(visit.title, current.tab!!.title)
        assertTrue(current.spaces.flatMap { it.tabs }.any { it.id == "front" && it.isBlank })
        assertEquals(privateTab.url, current.spaces.flatMap { it.tabs }.single { it.id == privateTab.id }.url)
        assertEquals(BrowserSpace.SHARED_PROFILE, engine.navigated.single().second.id)
    }

    @Test fun emptyKeptTabIsReusedButPinnedBlankIsNeverOverwritten() = runTest {
        for (place in listOf(TabPlace.KEPT, TabPlace.PINNED)) {
            val engine = Engine()
            val front = BrowserTab("front-$place", place = place, createdAt = now)
            val browser = BrowserController(Repo(snapshot(front)), engine, backgroundScope, now = { now })
            runCurrent()
            browser.show(BrowserSurface.HISTORY)
            assertTrue(browser.openHistoryVisit(browser.captureHistoryPresentation()!!, visit))
            val current = browser.state.value
            assertEquals(visit.url, current.tab!!.url)
            assertEquals(visit.title, current.tab!!.title)
            if (place == TabPlace.KEPT) { assertEquals(front.id, current.tab!!.id); assertEquals(place, current.tab!!.place) }
            else { assertNotEquals(front.id, current.tab!!.id); assertTrue(current.space!!.tabs.single { it.id == front.id }.isBlank) }
        }
    }

    @Test fun existingSamePrettyAddressWinsWithoutReloadOrDuplicateAndNonblankFrontSurvives() = runTest {
        val front = BrowserTab("front", "https://other.test", "Keep me", createdAt = now)
        val existing = BrowserTab("open", "http://example.test/article?q=one#part", "Already open", place = TabPlace.PINNED, createdAt = now)
        val initial = snapshot(front).let { it.copy(spaces = listOf(it.spaces.single().copy(tabs = listOf(front, existing)))) }
        val engine = Engine()
        val browser = BrowserController(Repo(initial), engine, backgroundScope, now = { now })
        runCurrent(); browser.show(BrowserSurface.HISTORY)
        assertTrue(browser.openHistoryVisit(browser.captureHistoryPresentation()!!, visit))
        assertEquals(existing.id, browser.state.value.tab!!.id)
        assertEquals(2, browser.state.value.space!!.tabs.size)
        assertEquals(front.url, browser.state.value.space!!.tabs.single { it.id == front.id }.url)
        assertTrue(engine.navigated.isEmpty())
    }

    @Test fun oldRowsDialogsAndCloseNeverBorrowForegroundReopenOrAccountAuthority() = runTest {
        val browser = BrowserController(Repo(snapshot()), Engine(), backgroundScope, now = { now })
        runCurrent(); browser.show(BrowserSurface.HISTORY)
        val stopped = browser.captureHistoryPresentation()!!
        browser.backgrounded(); browser.foregrounded()
        assertFalse(browser.openHistoryVisit(stopped, visit)); assertFalse(browser.deleteHistoryVisit(stopped, visit))
        assertFalse(browser.clearHistory(stopped, HistoryRange.ALL_TIME)); assertFalse(browser.dismissHistory(stopped))
        val first = browser.captureHistoryPresentation()!!
        browser.dismissSurface(); browser.show(BrowserSurface.HISTORY)
        assertFalse(browser.clearHistory(first, HistoryRange.ALL_TIME))
        val account = browser.captureHistoryPresentation()!!
        browser.invalidateLocalOwnership()
        assertFalse(browser.openHistoryVisit(account, visit)); assertFalse(browser.deleteHistoryVisit(account, visit))
        assertFalse(browser.dismissHistory(account)); assertFalse(browser.clearHistory(account, HistoryRange.ALL_TIME))
        assertEquals(listOf(visit), browser.state.value.history)
    }

    @Test fun importedRowRefreshRejectsOldDeleteAndNavigationDespiteSameIdentity() = runTest {
        val old = visit.copy(syncedKey = "example.test/article", syncedAt = now / 1000.0, syncedDevice = "mac")
        val browser = BrowserController(Repo(snapshot(history = listOf(old))), Engine(), backgroundScope, now = { now })
        runCurrent(); browser.show(BrowserSurface.HISTORY)
        val lease = browser.captureHistoryPresentation()!!
        val fresh = old.copy(title = "New Mac visit", visitedAt = now + 1, syncedAt = old.syncedAt!! + 0.001)
        browser.applySyncedSnapshot(browser.publicSnapshot()!!.copy(history = listOf(fresh)))
        assertFalse(browser.deleteHistoryVisit(lease, old)); assertFalse(browser.openHistoryVisit(lease, old))
        assertEquals(listOf(fresh), browser.state.value.history)
        assertTrue(browser.deleteHistoryVisit(lease, fresh))
        assertEquals(fresh.syncedAt, browser.state.value.historyForgetting.places[fresh.syncedKey])
    }

    @Test fun sameTurnProfileAndFrontABANeverRevivesAnOldHistoryLease() = runTest {
        val browser = BrowserController(Repo(snapshot()), Engine(), backgroundScope, now = { now })
        runCurrent(); browser.show(BrowserSurface.HISTORY)
        val original = browser.captureHistoryPresentation()!!
        val public = browser.publicSnapshot()!!
        browser.applySyncedSnapshot(public.copy(spaces = public.spaces.map { it.copy(ownSignIns = true) }))
        browser.applySyncedSnapshot(public)
        assertFalse(browser.historyActionsCurrent(original))
        assertFalse(browser.openHistoryVisit(original, visit)); assertFalse(browser.deleteHistoryVisit(original, visit))
        assertFalse(browser.clearHistory(original, HistoryRange.ALL_TIME)); assertFalse(browser.dismissHistory(original))
        assertTrue(browser.historyActionsCurrent(browser.captureHistoryPresentation()!!))
        val front = browser.captureHistoryPresentation()!!
        val empty = public.copy(spaces = public.spaces.map { it.copy(tabs = emptyList(), currentTabId = null) })
        browser.applySyncedSnapshot(empty); browser.applySyncedSnapshot(public)
        assertFalse(browser.historyActionsCurrent(front))
        assertEquals(listOf(visit), browser.state.value.history)
        assertTrue(browser.openHistoryVisit(browser.captureHistoryPresentation()!!, visit))
    }

    @Test fun sameTurnFrontUrlABANeverRevivesAnOriginalSource() = runTest {
        val front = BrowserTab("front", "https://source-a.test/", "Original", createdAt = now)
        val browser = BrowserController(Repo(snapshot(front)), Engine(), backgroundScope, now = { now })
        runCurrent(); browser.show(BrowserSurface.HISTORY)
        val original = browser.captureHistoryPresentation()!!
        val epoch = browser.state.value.surfaceEpoch
        val generation = browser.historyPresentationLifetime.value
        browser.pageChanged(front.id, EnginePageState(url = "https://source-b.test/", title = front.title))
        browser.pageChanged(front.id, EnginePageState(url = front.url, title = front.title))
        assertEquals(epoch, browser.state.value.surfaceEpoch)
        assertEquals(front.id, browser.state.value.tab?.id)
        assertEquals(front.url, browser.state.value.tab?.url)
        assertEquals(generation + 2, browser.historyPresentationLifetime.value)
        assertFalse(browser.historyActionsCurrent(original))
        assertFalse(browser.openHistoryVisit(original, visit)); assertFalse(browser.deleteHistoryVisit(original, visit))
        assertFalse(browser.clearHistory(original, HistoryRange.ALL_TIME)); assertFalse(browser.dismissHistory(original))
        val fresh = browser.captureHistoryPresentation()!!
        assertTrue(browser.historyActionsCurrent(fresh))
        assertEquals(listOf(visit), browser.state.value.history)
        assertTrue(browser.deleteHistoryVisit(fresh, visit))
        assertTrue(browser.state.value.history.isEmpty())
    }

    @Test fun currentTodayAndYesterdayClearKeepsEarlierLocalAndHidesOnlyInclusiveRemoteSpan() = runTest {
        val zone = ZoneId.of("America/Los_Angeles")
        val start = HistoryRange.TODAY_AND_YESTERDAY.start(now, zone)
        val early = visit.copy(url = "https://before.test", visitedAt = start - 1)
        val edge = visit.copy(url = "https://edge.test", visitedAt = start)
        val remote = visit.copy(syncedKey = "example.test/article", syncedAt = now / 1000.0 + 0.0002, syncedDevice = "mac")
        val browser = BrowserController(Repo(snapshot(history = listOf(early, edge, remote))), Engine(), backgroundScope, now = { now })
        runCurrent(); browser.show(BrowserSurface.HISTORY)
        assertTrue(browser.clearHistory(browser.captureHistoryPresentation()!!, HistoryRange.TODAY_AND_YESTERDAY, zone))
        assertEquals(listOf(early), browser.state.value.history)
        val span = browser.state.value.historyForgetting.spans.single()
        assertEquals(start / 1000.0, span.from, 0.0)
        assertEquals(now / 1000.0 + 60, span.to, 0.0)
    }
}

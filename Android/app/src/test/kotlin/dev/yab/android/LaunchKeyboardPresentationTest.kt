package dev.yab.android

import dev.yab.browser.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LaunchKeyboardPresentationTest {
    private class Engine : BrowserEngine {
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun controller(scope: CoroutineScope, welcomed: Boolean = true): BrowserController {
        val tabs = listOf("a", "b", "c").map { BrowserTab(it, "https://$it.example", it, createdAt = 1) }
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Personal", tabs = tabs, currentTabId = "a")),
            selectedSpaceId = "s", settings = BrowserSettings(welcomed = welcomed))
        return BrowserController(object : BrowserRepository {
            override suspend fun load() = snapshot
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, Engine(), scope)
    }
    private fun source(c: BrowserController, epoch: Long = 1): LaunchKeyboardSource {
        val s = c.state.value; val life = c.settingsPresentationLifetime.value
        return LaunchKeyboardSource("account", "device", epoch, false, s.space?.id, s.space?.websiteProfile,
            s.tab?.id, s.tab?.url, s.surfaceEpoch, c.historyPresentationLifetime.value, life.generation, life.privateBoundary, life.active)
    }
    private fun presentation(c: BrowserController): Pair<LaunchKeyboardPresentation, Any> {
        val p = LaunchKeyboardPresentation(LaunchKeyboardCache(LaunchKeyboardMemory()) {})
        val owner = Any(); p.attach(owner)
        p.foreground(owner, false, true, Triple("account", "device", 1L), source(c), 1_000)
        return p to owner
    }

    @Test fun exactReadingThresholdAndFifteenMinuteBoundaryNeverTreatUnknownAsZero() {
        val base = LaunchKeyboardPolicy.Situation(LaunchKeyboardPolicy.Moment.LAUNCH, scroll = 200.0, awayMillis = 899_999)
        assertTrue(LaunchKeyboardPolicy.opens(base))
        assertFalse(LaunchKeyboardPolicy.opens(base.copy(scroll = 200.001)))
        assertTrue(LaunchKeyboardPolicy.opens(base.copy(scroll = 500.0, awayMillis = 900_000)))
        assertTrue(LaunchKeyboardPolicy.opens(base.copy(scroll = 500.0, awayMillis = null)))
        assertFalse(LaunchKeyboardPolicy.opens(base.copy(scroll = null)))
        assertTrue(LaunchKeyboardPolicy.opens(base.copy(scroll = 0.0)))
    }

    @Test fun explicitEntrancesWelcomePrivateAndEveryCoverDenyBeforeNoTabWhileBackKeepsPage() {
        val base = LaunchKeyboardPolicy.Situation(LaunchKeyboardPolicy.Moment.LAUNCH, hasTab = false)
        assertTrue(LaunchKeyboardPolicy.opens(base))
        for (blocked in listOf(base.copy(enabled = false), base.copy(asked = true), base.copy(welcome = true),
            base.copy(privateFront = true), base.copy(covered = true))) assertFalse(LaunchKeyboardPolicy.opens(blocked))
        assertFalse(LaunchKeyboardPolicy.opens(base.copy(moment = LaunchKeyboardPolicy.Moment.BACK, hasTab = true)))
        assertTrue(LaunchKeyboardPolicy.opens(base.copy(moment = LaunchKeyboardPolicy.Moment.BACK)))
    }

    @Test fun actualControllerNewTabRetainsFrontPairAndConsumesExactlyOneOriginalArrival() = runTest {
        val c = controller(backgroundScope); runCurrent()
        c.invalidateWorkspaceWindow(); assertTrue(c.commitWorkspaceWindow(c.workspaceWindow.value.configuration, BrowserWorkspaceWindow(1280.0, 800.0)))
        c.openBeside("b")
        val before = c.state.value; val (p, _) = presentation(c); val original = checkNotNull(p.arrival.value)
        assertTrue(p.consume(original, source(c), { true }) { c.openField(newTab = true, privately = false) })
        assertEquals(BrowserSurface.FIELD, c.state.value.surface); assertTrue(c.state.value.fieldIsNewTab)
        assertFalse(c.state.value.fieldIsPrivate); assertEquals(before.workspace, c.state.value.workspace)
        assertEquals(before.tab?.id, c.state.value.tab?.id)
        assertFalse(p.consume(original, source(c), { true }) { error("Old arrival replayed") })
    }

    @Test fun actualFrontAndProfileSourceAbaCannotReopenTheOldArrival() = runTest {
        val c = controller(backgroundScope); runCurrent(); val (p, _) = presentation(c); val original = checkNotNull(p.arrival.value)
        val first = source(c); c.selectTab("b"); c.selectTab("a")
        assertEquals(first.tab, source(c).tab); assertNotEquals(first.history, source(c).history)
        assertFalse(p.consume(original, source(c), { true }) { c.openField() })
        assertNull(p.arrival.value); assertEquals(BrowserSurface.PAGE, c.state.value.surface)
        val (profileArrival, _) = presentation(c); val beforeProfile = checkNotNull(profileArrival.arrival.value)
        val snapshot = checkNotNull(c.publicSnapshot())
        c.applySyncedSnapshot(snapshot.copy(spaces = snapshot.spaces.map { it.copy(ownSignIns = true) }))
        c.applySyncedSnapshot(snapshot)
        assertEquals(beforeProfile.source?.profile, source(c).profile)
        assertFalse(profileArrival.consume(beforeProfile, source(c), { true }) { error("Profile ABA opened") })
        val (stopArrival, _) = presentation(c); val beforeStop = checkNotNull(stopArrival.arrival.value)
        c.backgrounded()
        assertFalse(stopArrival.consume(beforeStop, source(c), { true }) { error("STOP opened") })
        assertEquals(BrowserSurface.PAGE, c.state.value.surface)
    }

    @Test fun configurationReattachmentDoesNotBecomeColdLaunchAndRealBackgroundCreatesOnlyBack() = runTest {
        val c = controller(backgroundScope); runCurrent(); val (p, owner) = presentation(c); val old = checkNotNull(p.arrival.value)
        p.background(owner, true); val replacement = Any(); p.attach(replacement)
        p.foreground(replacement, false, true, Triple("account", "device", 1L), source(c), 2_000)
        assertNull(p.arrival.value)
        assertFalse(p.consume(old, source(c), { true }) { c.openField() })
        p.background(replacement, false)
        p.foreground(replacement, false, true, Triple("account", "device", 1L), source(c), 3_000)
        assertEquals(LaunchKeyboardPolicy.Moment.BACK, p.arrival.value?.moment)
    }

    @Test fun skippedWelcomeCannotOpenAfterCompletionAndFreshUnfocusedDebugIsNotFixtureSuppressed() = runTest {
        val c = controller(backgroundScope, welcomed = false); runCurrent(); val (p, _) = presentation(c)
        val original = checkNotNull(p.arrival.value)
        assertFalse(LaunchKeyboardPolicy.opens(LaunchKeyboardPolicy.Situation(original.moment, welcome = !c.state.value.settings.welcomed)))
        p.retire(original); c.updateSettings(c.state.value.settings.copy(welcomed = true))
        assertFalse(p.consume(original, source(c), { true }) { c.openField() })
        assertTrue(LaunchKeyboardPolicy.fixtureAllowed(false, false))
        assertFalse(LaunchKeyboardPolicy.fixtureAllowed(true, false))
        assertTrue(LaunchKeyboardPolicy.fixtureAllowed(true, true))
        assertEquals(BrowserSurface.PAGE, c.state.value.surface)
    }

    @Test fun firstLoadedSourceIsPinnedAndAccountOrNoRenderGenerationChangesRetireIt() = runTest {
        val c = controller(backgroundScope); runCurrent()
        val p = LaunchKeyboardPresentation(LaunchKeyboardCache(LaunchKeyboardMemory()) {}); val owner = Any(); p.attach(owner)
        p.foreground(owner, false, true, Triple("account", "device", 1L), null, 1_000)
        p.loaded(source(c)); val original = checkNotNull(p.arrival.value)
        p.loaded(source(c).copy(history = source(c).history + 1)); p.loaded(source(c))
        assertFalse(p.consume(original, source(c), { true }) { c.openField() })
        p.background(owner, false); p.foreground(owner, false, true, Triple("account", "device", 1L), source(c), 2_000)
        p.loaded(source(c, epoch = 2)); assertNull(p.arrival.value)
    }

    @Test fun staleUnboundSnapshotCannotRetireOrConsumeTheFreshPinnedBindingOfItsOwnArrival() = runTest {
        val c = controller(backgroundScope); runCurrent()
        val p = LaunchKeyboardPresentation(LaunchKeyboardCache(LaunchKeyboardMemory()) {}); val owner = Any(); p.attach(owner)
        p.foreground(owner, false, true, Triple("account", "device", 1L), null, 1_000)
        val unbound = checkNotNull(p.arrival.value); p.loaded(source(c)); val pinned = checkNotNull(p.arrival.value)
        assertNotSame(unbound, pinned); assertSame(unbound.token, pinned.token)
        p.retire(unbound); assertSame(pinned, p.arrival.value)
        assertFalse(p.consume(unbound, source(c), { true }) { error("Unbound snapshot opened") })
        assertSame(pinned, p.arrival.value)
        assertTrue(p.consume(pinned, source(c), { true }) { c.openField() })
        assertEquals(BrowserSurface.FIELD, c.state.value.surface)
    }

    @Test fun reentrantHostReplacementCannotBorrowFreshAuthorityOrEraseItsNewArrival() = runTest {
        val c = controller(backgroundScope); runCurrent(); val (p, owner) = presentation(c); val old = checkNotNull(p.arrival.value)
        val next = Any()
        assertFalse(p.consume(old, source(c), {
            p.background(owner, false); p.attach(next)
            p.foreground(next, false, true, Triple("account", "device", 1L), source(c), 3_000); true
        }) { error("Old action borrowed successor") })
        assertNotNull(p.arrival.value); assertSame(next, p.arrival.value?.owner)
    }

    @Test fun publicCachePreservesColdKnowledgeAcrossStartupZeroAndNeverPersistsPrivateOrConfigStop() = runTest {
        val c = controller(backgroundScope); runCurrent(); val front = checkNotNull(LaunchKeyboardFront.capture(c.state.value, "a", "d"))
        val writes = mutableListOf<LaunchKeyboardMemory>()
        val cache = LaunchKeyboardCache(LaunchKeyboardMemory(1_000, front, 450.0)) { writes += it }
        val original = source(c); val document = Any(); cache.reconcile(front, original)
        cache.observe(front, 0.0, original, document)
        assertEquals(450.0, cache.cold.scrollFor(front)!!, 0.0)
        assertFalse(cache.background(front, original, 2_000, true) { true }); assertTrue(writes.isEmpty())
        val privateState = c.state.value.copy(spaces = c.state.value.spaces.map { it.copy(isPrivate = true) })
        assertNull(LaunchKeyboardFront.capture(privateState, "a", "d"))
        assertNull(LaunchKeyboardFront.capture(c.state.value.copy(surface = BrowserSurface.FIELD, fieldPrivate = true), "a", "d"))
        assertTrue(cache.background(front, original, 2_000, false) { it === document }); assertEquals(0.0, writes.single().scroll!!, 0.0)
        assertNull(cache.cold.scrollFor(front.copy(url = "https://new.example")))
        assertNull(cache.cold.scrollFor(front.copy(profile = "another")))
        assertNull(cache.cold.scrollFor(front.copy(account = "replacement")))
        assertFalse(cache.background(null, original, 2_000, false) { true }); assertEquals(LaunchKeyboardMemory(), writes.last())
    }

    @Test fun actualNavigationAbaAndErasureCannotPersistAnOldDocumentScrollUnderTheSameUrl() = runTest {
        val c = controller(backgroundScope); runCurrent(); val front = checkNotNull(LaunchKeyboardFront.capture(c.state.value, "a", "d"))
        val writes = mutableListOf<LaunchKeyboardMemory>()
        val cache = LaunchKeyboardCache(LaunchKeyboardMemory(1_000, front, 450.0)) { writes += it }
        val first = source(c); val document = Any(); cache.reconcile(front, first); cache.observe(front, 600.0, first, document)
        c.selectTab("b"); c.selectTab("a"); val returned = source(c)
        assertNotEquals(first.history, returned.history); cache.reconcile(front, returned)
        assertTrue(cache.background(front, returned, 2_000, false) { error("Retired document must not be queried") })
        assertNull(writes.last().scroll)
        cache.observe(front, 700.0, returned, document)
        assertTrue(cache.background(front, returned, 3_000, false) { false }); assertNull(writes.last().scroll)
        cache.reconcile(front, returned, erased = true); assertEquals(LaunchKeyboardMemory(), writes.last())
        cache.observe(front, 0.0, returned, Any()); cache.reconcile(null, returned)
        assertEquals(LaunchKeyboardMemory(), writes.last())
        // A first unknown-scroll save still owns a disk record even though cold input stays empty.
        val freshWrites = mutableListOf<LaunchKeyboardMemory>()
        val fresh = LaunchKeyboardCache(LaunchKeyboardMemory()) { freshWrites += it }
        fresh.reconcile(front, returned)
        assertTrue(fresh.background(front, returned, 4_000, false) { error("No observed document") })
        assertEquals(front, freshWrites.last().front)
        fresh.reconcile(null, returned); assertEquals(LaunchKeyboardMemory(), freshWrites.last())
        assertEquals(2, freshWrites.size)
    }

    @Test fun boundedCacheRoundtripRejectsInvalidValuesAndClockRollbackHasNoNegativeAway() {
        val front = LaunchKeyboardFront(null, null, "s", "a", "shared", "https://example.test")
        val original = LaunchKeyboardMemory(1_000, front, 240.0)
        assertEquals(original, Json.decodeFromString<LaunchKeyboardMemory>(Json.encodeToString(original)))
        assertEquals(0L, original.away(900)); assertEquals(200L, original.away(1_200))
        assertFalse(original.copy(scroll = Double.NaN).valid())
        assertFalse(original.copy(front = front.copy(url = "x".repeat(8193))).valid())
        assertFalse(original.copy(front = null).valid())
    }

    @Test fun recentReadingFromAnotherFrontCannotSuppressAnActualColdNewTabOnB() = runTest {
        val c = controller(backgroundScope); runCurrent()
        val a = checkNotNull(LaunchKeyboardFront.capture(c.state.value, "account", "device"))
        val memory = LaunchKeyboardMemory(1_000, a, 450.0)
        c.selectTab("b"); val b = checkNotNull(LaunchKeyboardFront.capture(c.state.value, "account", "device"))
        assertNull(memory.scrollFor(b)); assertNull(memory.ownedAway(b, memory.away(2_000)))
        val p = LaunchKeyboardPresentation(LaunchKeyboardCache(memory) {}); val owner = Any(); p.attach(owner)
        p.foreground(owner, false, true, Triple("account", "device", 1L), source(c), 2_000)
        val original = checkNotNull(p.arrival.value)
        assertTrue(LaunchKeyboardPolicy.opens(LaunchKeyboardPolicy.Situation(original.moment,
            scroll = memory.scrollFor(b), awayMillis = memory.ownedAway(b, original.awayMillis))))
        assertTrue(p.consume(original, source(c), { true }) { c.openField(newTab = true, privately = false) })
        assertEquals("b", c.state.value.tab?.id); assertEquals(BrowserSurface.FIELD, c.state.value.surface)
    }
}

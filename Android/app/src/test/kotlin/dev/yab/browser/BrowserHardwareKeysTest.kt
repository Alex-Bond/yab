package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserHardwareKeysTest {
    private fun tab(id: String, place: TabPlace = TabPlace.TODAY, folder: String? = null) =
        BrowserTab(id, "https://$id.test", id, place, createdAt = 1, folderId = folder)
    private val first = tab("a")
    private fun space(tabs: List<BrowserTab> = listOf(first), selected: String? = tabs.firstOrNull()?.id) =
        BrowserSpace("s", "Personal", tabs = tabs, currentTabId = selected)
    private class Engine : BrowserEngine {
        val events = mutableListOf<String>()
        var readerAccepted = true
        var reenter: (() -> Unit)? = null
        var onClose: ((String) -> Unit)? = null
        var onFind: (() -> Unit)? = null
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { events += "navigate:${tab.id}" }
        override fun close(tabId: String) { events += "close:$tabId"; onClose?.invoke(tabId) }
        override fun goBack(tabId: String) { events += "back:$tabId" }
        override fun goForward(tabId: String) { events += "forward:$tabId" }
        override fun reload(tabId: String) { events += "reload:$tabId"; reenter?.invoke() }
        override fun stop(tabId: String) { events += "stop:$tabId" }
        override fun setReader(tabId: String, enabled: Boolean): Boolean {
            events += "reader:$tabId:$enabled"; return readerAccepted
        }
        override fun find(tabId: String, query: BrowserFindQuery, direction: BrowserFindDirection,
            answer: (BrowserFindResult?) -> Unit): Boolean {
            events += "find:$tabId:${query.text}"; onFind?.invoke(); return true
        }
        override fun clearFind(tabId: String) { events += "clearFind:$tabId" }
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun newBrowser(scope: CoroutineScope, engine: Engine = Engine(), original: BrowserSpace = space(),
        clock: () -> Long = { 1L }, otherSpaces: List<BrowserSpace> = emptyList()): BrowserController {
        var next = 0
        return BrowserController(object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = otherSpaces + original, selectedSpaceId = original.id)
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope, now = clock, newId = { "new-${next++}" },
            activityClock = { TabActivityClock(clock(), clock(), 1, "process") })
    }
    private fun lease(browser: BrowserController, key: BrowserHardwareKey,
        host: BrowserHardwareKeyHost = BrowserHardwareKeyHost { true }) =
        checkNotNull(browser.captureHardwareKey(key, host))
    private fun use(browser: BrowserController, key: BrowserHardwareKey): Boolean =
        browser.captureHardwareKey(key, BrowserHardwareKeyHost { true })?.let(browser::performHardwareKey) == true

    @Test fun exactNineteenChordsSupportControlAndMetaWithoutTakingSystemMetaTab() {
        val plain = listOf("t", "l", "w", "r", "[", "]", "f") + (1..9).map(Int::toString)
        val commands = listOf(BrowserHardwareKey.NEW_TAB, BrowserHardwareKey.OPEN_LOCATION,
            BrowserHardwareKey.CLOSE_TAB, BrowserHardwareKey.RELOAD, BrowserHardwareKey.BACK,
            BrowserHardwareKey.FORWARD, BrowserHardwareKey.FIND) + BrowserHardwareKey.entries.filter { it.name.startsWith("TAB_") }
        for ((input, expected) in plain.zip(commands)) {
            assertEquals(expected, BrowserHardwareKey.fromChord(input, control = true, meta = false))
            assertEquals(expected, BrowserHardwareKey.fromChord(input, control = false, meta = true))
        }
        assertEquals(BrowserHardwareKey.REOPEN_TAB, BrowserHardwareKey.fromChord("t", true, false, shift = true))
        assertEquals(BrowserHardwareKey.REOPEN_TAB, BrowserHardwareKey.fromChord("t", false, true, shift = true))
        assertEquals(BrowserHardwareKey.NEXT_TAB, BrowserHardwareKey.fromChord("\t", true, false))
        assertEquals(BrowserHardwareKey.PREVIOUS_TAB, BrowserHardwareKey.fromChord("\t", true, false, shift = true))
        assertNull(BrowserHardwareKey.fromChord("\t", false, true))
        assertNull(BrowserHardwareKey.fromChord("\t", false, true, shift = true))
        assertEquals(19, BrowserHardwareKey.entries.size)
    }

    @Test fun extraModifiersUnknownInputsAndRepeatEventsCannotProduceAnyBrowserCommand() {
        for (input in listOf("t", "l", "w", "r", "[", "]", "f", "1", "9", "\t")) {
            assertNull(BrowserHardwareKey.fromChord(input, false, false))
            assertNull(BrowserHardwareKey.fromChord(input, true, true))
            assertNull(BrowserHardwareKey.fromChord(input, true, false, alt = true))
            assertNull(BrowserHardwareKey.fromChord(input, true, false, repeatCount = 1))
            assertNull(BrowserHardwareKey.fromChord(input, true, false, repeatCount = -1))
            if (input !in listOf("t", "\t")) assertNull(BrowserHardwareKey.fromChord(input, true, false, shift = true))
        }
        for (input in listOf("", "T", "0", "10", "escape", "enter", "x"))
            assertNull(BrowserHardwareKey.fromChord(input, true, false))
    }

    @Test fun newTabAndLocationOpenTheRealFieldWithoutCreatingOrNavigatingATab() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        assertTrue(use(browser, BrowserHardwareKey.NEW_TAB))
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        assertTrue(browser.state.value.fieldIsNewTab)
        assertEquals(listOf(first), browser.state.value.space!!.tabs)
        assertTrue(engine.events.isEmpty())
        assertTrue(use(browser, BrowserHardwareKey.CLOSE_TAB))
        assertTrue(use(browser, BrowserHardwareKey.OPEN_LOCATION))
        assertFalse(browser.state.value.fieldIsNewTab)
        assertEquals(first.url, browser.state.value.fieldText)
        assertEquals(first.id, browser.state.value.fieldOriginTab)
        assertTrue(engine.events.isEmpty())
    }

    @Test fun emptyPageAllowsNewTabButNeverInventsCloseHistoryFindOrNumberedTargets() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space(emptyList())); runCurrent()
        for (key in BrowserHardwareKey.entries.filterNot { it == BrowserHardwareKey.NEW_TAB })
            assertNull(browser.captureHardwareKey(key, BrowserHardwareKeyHost { true }))
        assertTrue(use(browser, BrowserHardwareKey.NEW_TAB))
        assertTrue(browser.state.value.space!!.tabs.isEmpty())
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        assertTrue(use(browser, BrowserHardwareKey.CLOSE_TAB))
        assertNull(browser.state.value.tab)
        assertTrue(engine.events.isEmpty())
    }

    @Test fun fieldCloseUsesItsOriginalEpochWhileTypingRemainsTheSameEditor() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        browser.openField(newTab = false)
        val close = lease(browser, BrowserHardwareKey.CLOSE_TAB)
        browser.fieldText("an unfinished address")
        assertTrue(browser.hardwareKeyCurrent(close))
        for (key in BrowserHardwareKey.entries.filterNot { it == BrowserHardwareKey.CLOSE_TAB })
            assertNull(browser.captureHardwareKey(key, BrowserHardwareKeyHost { true }))
        assertTrue(browser.performHardwareKey(close)); assertFalse(browser.performHardwareKey(close))
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        assertEquals(first.id, browser.state.value.tab?.id)
        assertFalse(browser.state.value.undoAvailable); assertTrue(engine.events.isEmpty())
        browser.openField(newTab = false)
        assertFalse(browser.performHardwareKey(close))
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
    }

    @Test fun modalSurfacesRefuseEveryChordAndReturningDoesNotReviveTheOldPageLease() = runTest {
        for (surface in listOf(BrowserSurface.SETTINGS, BrowserSurface.HISTORY, BrowserSurface.SPACES, BrowserSurface.GALLERY)) {
            val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
            val old = lease(browser, BrowserHardwareKey.CLOSE_TAB)
            browser.show(surface)
            for (key in BrowserHardwareKey.entries) assertNull(browser.captureHardwareKey(key, BrowserHardwareKeyHost { true }))
            browser.show(BrowserSurface.PAGE)
            assertFalse(browser.performHardwareKey(old)); assertTrue(engine.events.isEmpty())
            assertTrue(use(browser, BrowserHardwareKey.RELOAD))
            assertEquals(listOf("reload:a"), engine.events)
        }
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        browser.updateSettings(browser.state.value.settings.copy(welcomed = true))
        val boundary = lease(browser, BrowserHardwareKey.RELOAD)
        browser.updateSettings(browser.state.value.settings.copy(welcomed = false))
        assertFalse(browser.performHardwareKey(boundary)); assertTrue(engine.events.isEmpty())
        browser.updateSettings(browser.state.value.settings.copy(welcomed = true))
        val unobservedAba = lease(browser, BrowserHardwareKey.RELOAD)
        browser.updateSettings(browser.state.value.settings.copy(welcomed = false))
        browser.updateSettings(browser.state.value.settings.copy(welcomed = true))
        assertFalse(browser.performHardwareKey(unobservedAba)); assertTrue(engine.events.isEmpty())
        assertTrue(use(browser, BrowserHardwareKey.RELOAD)); assertEquals(listOf("reload:a"), engine.events)
    }

    @Test fun reloadAlwaysReloadsAnAlreadyLoadingPageAndConsumesBeforeEngineReentry() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        browser.pageChanged(first.id, EnginePageState(loading = true))
        val reload = lease(browser, BrowserHardwareKey.RELOAD)
        engine.reenter = { assertFalse(browser.performHardwareKey(reload)) }
        assertTrue(browser.performHardwareKey(reload)); assertFalse(browser.performHardwareKey(reload))
        assertEquals(listOf("reload:a"), engine.events)
    }

    @Test fun reloadWithoutStateEmissionPublishesAFreshRenderGenerationButNeverReusesTheOldCallback() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        val original = lease(browser, BrowserHardwareKey.RELOAD)
        val state = browser.state.value
        val generation = browser.hardwareKeyRevision.value
        assertTrue(browser.performHardwareKey(original))
        assertSame(state, browser.state.value)
        assertEquals(generation + 1, browser.hardwareKeyRevision.value)
        assertFalse(browser.performHardwareKey(original))
        val fresh = lease(browser, BrowserHardwareKey.RELOAD)
        assertTrue(browser.performHardwareKey(fresh))
        assertEquals(generation + 2, browser.hardwareKeyGeneration)
        assertEquals(listOf("reload:a", "reload:a"), engine.events)
    }

    @Test fun backLeavesReaderFirstAndARefusedReaderExitNeverFallsThroughToHistory() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        browser.pageChanged(first.id, EnginePageState(readerEnabled = true, canGoBack = true))
        engine.readerAccepted = false
        assertFalse(use(browser, BrowserHardwareKey.BACK))
        assertEquals(listOf("reader:a:false"), engine.events)
        engine.readerAccepted = true
        assertTrue(use(browser, BrowserHardwareKey.BACK))
        browser.pageChanged(first.id, EnginePageState(canGoBack = true))
        assertTrue(use(browser, BrowserHardwareKey.BACK))
        assertEquals(listOf("reader:a:false", "reader:a:false", "back:a"), engine.events)
    }

    @Test fun nativeHistoryPrecedesOpenerAndOriginalOpenerCloseCanBeUndone() = runTest {
        val child = tab("child").copy(openerId = first.id)
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space(listOf(first, child), child.id)); runCurrent()
        browser.pageChanged(child.id, EnginePageState(canGoBack = true))
        assertTrue(use(browser, BrowserHardwareKey.BACK))
        assertEquals(child.id, browser.state.value.tab?.id)
        browser.pageChanged(child.id, EnginePageState())
        assertTrue(use(browser, BrowserHardwareKey.BACK))
        assertEquals(first.id, browser.state.value.tab?.id)
        assertEquals(listOf("back:child", "close:child"), engine.events)
        assertTrue(use(browser, BrowserHardwareKey.REOPEN_TAB))
        assertEquals(child.id, browser.state.value.tab?.id)
        assertNull(browser.captureHardwareKey(BrowserHardwareKey.REOPEN_TAB, BrowserHardwareKeyHost { true }))
    }

    @Test fun openerFollowupSelectsItsOriginalNonfirstTargetAfterHarmlessEngineMetadataReentry() = runTest {
        val decoy = tab("decoy")
        val child = tab("child").copy(openerId = first.id)
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space(listOf(decoy, first, child), child.id)); runCurrent()
        engine.onClose = { id -> if (id == child.id) {
            engine.onClose = null
            browser.pageChanged(decoy.id, EnginePageState(title = "Metadata", progress = .5f))
        } }
        assertTrue(use(browser, BrowserHardwareKey.BACK))
        assertEquals(first.id, browser.state.value.tab?.id)
        assertEquals(listOf("close:child"), engine.events)
        assertTrue(use(browser, BrowserHardwareKey.REOPEN_TAB)); assertEquals(child.id, browser.state.value.tab?.id)
    }

    @Test fun openerContinuationKeepsTheOriginalHostWhileAllowingOnlyItsOwnClosedNativeTargetToDisappear() = runTest {
        for (covered in listOf(false, true)) {
            val decoy = tab("decoy")
            val child = tab("child").copy(openerId = first.id)
            val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space(listOf(decoy, first, child), child.id)); runCurrent()
            var native = true; var context = true
            val host = BrowserHardwareKeyHost({ context && native }, { context })
            val action = lease(browser, BrowserHardwareKey.BACK, host)
            engine.onClose = { id -> if (id == child.id) {
                native = false
                context = !covered
            } }
            assertEquals(!covered, browser.performHardwareKey(action))
            assertEquals(first.id, browser.state.value.tab?.id)
            assertEquals(listOf("close:child"), engine.events)
            assertFalse(browser.performHardwareKey(action))
            if (covered) { context = true; assertFalse(host.continuationCurrent()) }
        }
    }

    @Test fun openerFollowupCannotSelectAfterReentrantAccountProfileWindowForegroundOrSelectionAba() = runTest {
        for (change in listOf("account", "profile", "window", "foreground", "selectionAba", "cover", "host", "hostWindow", "welcomeAba")) {
            val decoy = tab("decoy")
            val child = tab("child").copy(openerId = first.id)
            val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space(listOf(first, decoy, child), child.id)); runCurrent()
            val original = checkNotNull(browser.publicSnapshot())
            val other = BrowserSpace("other", "Other", tabs = listOf(tab("foreign")), currentTabId = "foreign")
            browser.applySyncedSnapshot(original.copy(spaces = original.spaces + other))
            if (change == "welcomeAba") browser.updateSettings(browser.state.value.settings.copy(welcomed = true))
            var hostCurrent = true
            var changeWindowOnRead = false
            val host = BrowserHardwareKeyHost({ hostCurrent }, {
                if (changeWindowOnRead) { changeWindowOnRead = false; browser.invalidateWorkspaceWindow() }
                hostCurrent
            })
            engine.onClose = { id -> if (id == child.id) {
                engine.onClose = null
                when (change) {
                    "account" -> browser.invalidateLocalOwnership()
                    "profile" -> browser.applySyncedSnapshot(checkNotNull(browser.publicSnapshot()).let { snapshot ->
                        snapshot.copy(spaces = snapshot.spaces.map { if (it.id == "s") it.copy(ownSignIns = true) else it })
                    })
                    "window" -> browser.invalidateWorkspaceWindow()
                    "foreground" -> { browser.backgrounded(); browser.foregrounded() }
                    "selectionAba" -> { browser.selectSpace(other.id); browser.selectSpace("s") }
                    "host" -> hostCurrent = false
                    "hostWindow" -> changeWindowOnRead = true
                    "welcomeAba" -> {
                        browser.updateSettings(browser.state.value.settings.copy(welcomed = false))
                        browser.updateSettings(browser.state.value.settings.copy(welcomed = true))
                    }
                    else -> browser.show(BrowserSurface.SETTINGS)
                }
            } }
            assertFalse(browser.performHardwareKey(lease(browser, BrowserHardwareKey.BACK, host)))
            assertEquals(decoy.id, browser.state.value.tab?.id)
            if (change == "cover") assertEquals(BrowserSurface.SETTINGS, browser.state.value.surface)
            assertFalse(browser.state.value.space!!.tabs.any { it.id == child.id })
        }
    }

    @Test fun findFollowupCannotRefocusOrIncrementTheEpochOfAReentrantSuccessor() = runTest {
        for (change in listOf("account", "window", "foreground", "cover", "newQuery", "host", "native", "hostQuery", "welcomeAba")) {
            val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
            if (change == "welcomeAba") browser.updateSettings(browser.state.value.settings.copy(welcomed = true))
            var successorEpoch = -1L
            var context = true; var native = true
            var replaceOnHostRead = false
            val host = BrowserHardwareKeyHost({
                if (replaceOnHostRead) { replaceOnHostRead = false; browser.find("successor") }
                context && native
            }, { context })
            engine.onFind = {
                engine.onFind = null
                when (change) {
                    "account" -> browser.invalidateLocalOwnership()
                    "window" -> browser.invalidateWorkspaceWindow()
                    "foreground" -> { browser.backgrounded(); browser.foregrounded() }
                    "cover" -> browser.openField(newTab = false)
                    "host" -> context = false
                    "native" -> native = false
                    "hostQuery" -> replaceOnHostRead = true
                    "welcomeAba" -> {
                        browser.updateSettings(browser.state.value.settings.copy(welcomed = false))
                        browser.updateSettings(browser.state.value.settings.copy(welcomed = true))
                    }
                    else -> browser.find("successor")
                }
                successorEpoch = browser.state.value.surfaceEpoch
            }
            assertFalse(browser.performHardwareKey(lease(browser, BrowserHardwareKey.FIND, host)))
            assertTrue(successorEpoch >= 0)
            assertEquals(successorEpoch, browser.state.value.surfaceEpoch)
            if (change in listOf("newQuery", "hostQuery")) assertEquals("successor", browser.state.value.find?.query?.text)
            if (change == "cover") assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        }
    }

    @Test fun forwardNeedsNativeAvailabilityAndOldRolesCannotReviveThroughSameTurnAba() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        assertNull(browser.captureHardwareKey(BrowserHardwareKey.FORWARD, BrowserHardwareKeyHost { true }))
        browser.pageChanged(first.id, EnginePageState(canGoForward = true))
        val forward = lease(browser, BrowserHardwareKey.FORWARD)
        browser.pageChanged(first.id, EnginePageState(canGoForward = false))
        browser.pageChanged(first.id, EnginePageState(canGoForward = true))
        assertFalse(browser.performHardwareKey(forward)); assertTrue(engine.events.isEmpty())
        assertTrue(use(browser, BrowserHardwareKey.FORWARD))
        assertEquals(listOf("forward:a"), engine.events)
    }

    @Test fun closingFocusedSplitPaneSelectsItsCompanionAndReopenIsOneUse() = runTest {
        val second = tab("b"); val engine = Engine()
        val browser = newBrowser(backgroundScope, engine, space(listOf(first, second))); runCurrent()
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(1366.0, 1024.0)))
        browser.openBeside(second.id)
        assertEquals(second.id, browser.state.value.workspace?.focused)
        assertTrue(use(browser, BrowserHardwareKey.CLOSE_TAB))
        assertEquals(first.id, browser.state.value.tab?.id); assertNull(browser.state.value.workspace)
        assertEquals(listOf("close:b"), engine.events)
        val reopen = lease(browser, BrowserHardwareKey.REOPEN_TAB)
        assertTrue(browser.performHardwareKey(reopen)); assertFalse(browser.performHardwareKey(reopen))
        assertEquals(second.id, browser.state.value.tab?.id)
        assertEquals(2, browser.state.value.space!!.tabs.size)
    }

    @Test fun lastTabCloseKeepsAnEmptyBrowserAndItsExactUndoReceiptCanExpire() = runTest {
        var clock = 1L; val engine = Engine()
        val browser = newBrowser(backgroundScope, engine, clock = { clock }); runCurrent()
        assertTrue(use(browser, BrowserHardwareKey.CLOSE_TAB)); assertNull(browser.state.value.tab)
        assertNull(browser.captureHardwareKey(BrowserHardwareKey.CLOSE_TAB, BrowserHardwareKeyHost { true }))
        val reopen = lease(browser, BrowserHardwareKey.REOPEN_TAB)
        clock += 100_000
        assertFalse(browser.performHardwareKey(reopen)); assertNull(browser.state.value.tab)
        assertEquals(listOf("close:a"), engine.events)
        assertTrue(use(browser, BrowserHardwareKey.NEW_TAB))
    }

    @Test fun numberedTabsUseKeptThenTodayOrderAndNineAlwaysMeansTheActualLast() = runTest {
        val kept = (1..3).map { tab("k$it", TabPlace.KEPT) }
        val today = (1..7).map { tab("t$it") }
        val browser = newBrowser(backgroundScope, original = space(today + kept)); runCurrent()
        val expected = kept + today
        val keys = listOf(BrowserHardwareKey.TAB_1, BrowserHardwareKey.TAB_2, BrowserHardwareKey.TAB_3,
            BrowserHardwareKey.TAB_4, BrowserHardwareKey.TAB_5, BrowserHardwareKey.TAB_6,
            BrowserHardwareKey.TAB_7, BrowserHardwareKey.TAB_8, BrowserHardwareKey.TAB_9)
        for ((index, key) in keys.withIndex()) {
            assertTrue(use(browser, key))
            assertEquals(expected[if (index == 8) expected.lastIndex else index].id, browser.state.value.tab?.id)
        }
    }

    @Test fun duplicateTargetIdsInAnEarlierForeignProfileCannotBorrowNumberedAdjacentOrOpenerActions() = runTest {
        val target = tab("target")
        val foreign = BrowserSpace("foreign", "Other sign-ins", ownSignIns = true,
            tabs = listOf(target.copy(url = "https://foreign.test")), currentTabId = target.id)
        for (key in listOf(BrowserHardwareKey.TAB_2, BrowserHardwareKey.TAB_9,
                BrowserHardwareKey.NEXT_TAB, BrowserHardwareKey.PREVIOUS_TAB, BrowserHardwareKey.BACK)) {
            val child = tab("child").copy(openerId = target.id)
            val tabs = when (key) {
                BrowserHardwareKey.PREVIOUS_TAB -> listOf(target, first)
                BrowserHardwareKey.BACK -> listOf(target, child)
                else -> listOf(first, target)
            }
            val front = if (key == BrowserHardwareKey.BACK) child.id else first.id
            val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space(tabs, front), otherSpaces = listOf(foreign)); runCurrent()
            assertEquals("s", browser.state.value.selectedSpaceId)
            assertNull(browser.captureHardwareKey(key, BrowserHardwareKeyHost { true }))
            assertFalse(use(browser, key)); assertEquals("s", browser.state.value.selectedSpaceId)
            assertEquals(front, browser.state.value.tab?.id)
            assertEquals(tabs.map(BrowserTab::id), browser.state.value.space!!.tabs.map(BrowserTab::id))
            assertTrue(engine.events.isEmpty())
        }
    }

    @Test fun cycleUsesAdjacentVisibleRowsIncludesRealBlankAndRefusesBothBoundariesWithoutWrapping() = runTest {
        val kept = tab("kept", TabPlace.KEPT)
        val blank = tab("blank").copy(url = "about:blank")
        val browser = newBrowser(backgroundScope, original = space(listOf(first, blank, kept), kept.id)); runCurrent()
        assertFalse(use(browser, BrowserHardwareKey.PREVIOUS_TAB)); assertEquals(kept.id, browser.state.value.tab?.id)
        assertTrue(use(browser, BrowserHardwareKey.NEXT_TAB)); assertEquals(first.id, browser.state.value.tab?.id)
        assertTrue(use(browser, BrowserHardwareKey.NEXT_TAB)); assertEquals(blank.id, browser.state.value.tab?.id)
        assertFalse(use(browser, BrowserHardwareKey.NEXT_TAB)); assertEquals(blank.id, browser.state.value.tab?.id)
        assertTrue(use(browser, BrowserHardwareKey.PREVIOUS_TAB)); assertEquals(first.id, browser.state.value.tab?.id)
    }

    @Test fun currentPinAndClosedFolderFrontAreInsertedButOtherHiddenRowsStayUnnumbered() = runTest {
        val pin = tab("pin", TabPlace.PINNED)
        val hidden = tab("hidden", TabPlace.KEPT, "folder")
        val original = space(listOf(hidden, first, pin), pin.id).copy(folders = listOf(BrowserFolder("folder", "Closed", open = false)))
        val browser = newBrowser(backgroundScope, original = original); runCurrent()
        assertNull(browser.captureHardwareKey(BrowserHardwareKey.TAB_3, BrowserHardwareKeyHost { true }))
        assertTrue(use(browser, BrowserHardwareKey.TAB_2)); assertEquals(first.id, browser.state.value.tab?.id)
        browser.selectTab(hidden.id)
        assertTrue(use(browser, BrowserHardwareKey.TAB_1)); assertEquals(hidden.id, browser.state.value.tab?.id)
        assertTrue(use(browser, BrowserHardwareKey.NEXT_TAB)); assertEquals(first.id, browser.state.value.tab?.id)
    }

    @Test fun selectedTabAndUrlAbaCannotLendAnOldKeyToAnIdenticalFinalPage() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space(listOf(first, tab("b")))); runCurrent()
        val old = lease(browser, BrowserHardwareKey.RELOAD)
        browser.selectTab("b"); browser.selectTab(first.id)
        assertFalse(browser.performHardwareKey(old))
        val oldUrl = lease(browser, BrowserHardwareKey.RELOAD)
        browser.pageChanged(first.id, EnginePageState(url = "https://changed.test"))
        browser.pageChanged(first.id, EnginePageState(url = first.url))
        assertFalse(browser.performHardwareKey(oldUrl)); assertTrue(engine.events.isEmpty())
        assertTrue(use(browser, BrowserHardwareKey.RELOAD)); assertEquals(listOf("reload:a"), engine.events)
    }

    @Test fun profileAndPagingOrderAbaRevokeEvenWithoutAnInterveningLeaseRead() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space(listOf(first, tab("b")))); runCurrent()
        val original = checkNotNull(browser.publicSnapshot())
        val profile = lease(browser, BrowserHardwareKey.RELOAD)
        browser.applySyncedSnapshot(original.copy(spaces = original.spaces.map { it.copy(ownSignIns = true) }))
        browser.applySyncedSnapshot(original)
        val profileBoundary = engine.events.toList()
        assertFalse(browser.performHardwareKey(profile)); assertEquals(profileBoundary, engine.events)
        val order = lease(browser, BrowserHardwareKey.TAB_2)
        browser.applySyncedSnapshot(original.copy(spaces = original.spaces.map { it.copy(tabs = it.tabs.reversed()) }))
        browser.applySyncedSnapshot(original)
        assertFalse(browser.performHardwareKey(order)); assertEquals(first.id, browser.state.value.tab?.id)
        assertEquals(profileBoundary, engine.events)
        assertTrue(use(browser, BrowserHardwareKey.TAB_2)); assertEquals("b", browser.state.value.tab?.id)
    }

    @Test fun fieldReopenAbaCannotCloseTheSuccessorEditor() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        browser.openField(newTab = false)
        val original = lease(browser, BrowserHardwareKey.CLOSE_TAB)
        browser.dismissField(browser.state.value.surfaceEpoch)
        browser.openField(newTab = false)
        assertFalse(browser.performHardwareKey(original))
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        assertTrue(engine.events.isEmpty()); assertTrue(use(browser, BrowserHardwareKey.CLOSE_TAB))
    }

    @Test fun privateLockRefusesEveryActionWhileUnlockedPrivateKeepsItsOwnProfile() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        browser.openUrl("https://private.test", privately = true)
        for (key in BrowserHardwareKey.entries) assertNull(browser.captureHardwareKey(key, BrowserHardwareKeyHost { true }))
        browser.unlockPrivate(true)
        val privateId = browser.state.value.tab!!.id
        assertTrue(use(browser, BrowserHardwareKey.RELOAD)); assertEquals("reload:$privateId", engine.events.last())
        assertTrue(use(browser, BrowserHardwareKey.OPEN_LOCATION)); assertTrue(browser.state.value.fieldIsPrivate)
        assertTrue(use(browser, BrowserHardwareKey.CLOSE_TAB)); assertEquals(privateId, browser.state.value.tab?.id)
        val old = lease(browser, BrowserHardwareKey.RELOAD)
        browser.lockPrivate(); browser.unlockPrivate(true)
        val boundary = engine.events.toList()
        assertFalse(browser.performHardwareKey(old)); assertEquals(boundary, engine.events)
    }

    @Test fun backgroundAndAccountBoundariesRevokeTheOriginalLeaseBeforeFreshStateIsRendered() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        val stopped = lease(browser, BrowserHardwareKey.RELOAD)
        browser.backgrounded(); browser.foregrounded()
        assertFalse(browser.performHardwareKey(stopped))
        val account = lease(browser, BrowserHardwareKey.RELOAD)
        browser.invalidateLocalOwnership()
        val boundary = engine.events.toList()
        assertFalse(browser.performHardwareKey(account)); assertEquals(boundary, engine.events)
        assertTrue(use(browser, BrowserHardwareKey.RELOAD)); assertEquals(boundary + "reload:a", engine.events)
    }

    @Test fun originalWindowAccountCoverAndDisposedHostRefusalsArePermanent() = runTest {
        for (reason in listOf("window", "account", "cover", "dispose")) {
            val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
            var current = true
            val host = BrowserHardwareKeyHost { current }
            val original = lease(browser, BrowserHardwareKey.RELOAD, host)
            if (reason == "dispose") host.retire() else { current = false; assertFalse(host.current()); current = true }
            assertFalse(browser.performHardwareKey(original)); assertTrue(engine.events.isEmpty())
            assertTrue(use(browser, BrowserHardwareKey.RELOAD)); assertEquals(listOf("reload:a"), engine.events)
        }
    }

    @Test fun monotonicHostGenerationRejectsAnUnobservedStopStartAbaAndFreshHostWorks() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        var generation = 0
        val captured = generation
        val original = lease(browser, BrowserHardwareKey.RELOAD, BrowserHardwareKeyHost { generation == captured })
        generation += 2
        assertFalse(browser.performHardwareKey(original)); assertTrue(engine.events.isEmpty())
        val freshGeneration = generation
        assertTrue(browser.performHardwareKey(lease(browser, BrowserHardwareKey.RELOAD,
            BrowserHardwareKeyHost { generation == freshGeneration })))
        assertEquals(listOf("reload:a"), engine.events)
    }

    @Test fun titleProgressAndFieldTypingDoNotReplaceTheSameActionOwner() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        val original = lease(browser, BrowserHardwareKey.RELOAD)
        browser.pageChanged(first.id, EnginePageState(title = "Updated title", progress = .75f))
        assertTrue(browser.performHardwareKey(original)); assertEquals(listOf("reload:a"), engine.events)
        browser.openField(newTab = false)
        val close = lease(browser, BrowserHardwareKey.CLOSE_TAB)
        browser.fieldText("typed")
        assertTrue(browser.performHardwareKey(close)); assertEquals(first.id, browser.state.value.tab?.id)
    }

    @Test fun reentrantHostChangesCannotMintOrExecuteEarlierStateAndForeignControllersCannotUseLeases() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        var armed = false
        val host = BrowserHardwareKeyHost { if (armed) browser.openField(); true }
        val original = lease(browser, BrowserHardwareKey.RELOAD, host)
        armed = true
        assertFalse(browser.performHardwareKey(original)); assertTrue(engine.events.isEmpty())
        browser.dismissField(browser.state.value.surfaceEpoch)
        assertNull(browser.captureHardwareKey(BrowserHardwareKey.RELOAD, BrowserHardwareKeyHost {
            browser.openField(); true
        }))
        browser.dismissField(browser.state.value.surfaceEpoch)
        val foreign = newBrowser(backgroundScope); runCurrent()
        assertFalse(foreign.performHardwareKey(lease(browser, BrowserHardwareKey.RELOAD)))
    }

    @Test fun repeatedFindRefocusesThroughEpochWithoutClearingTheExistingOriginalQuery() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent()
        val epoch = browser.state.value.surfaceEpoch
        assertTrue(use(browser, BrowserHardwareKey.FIND))
        assertNotNull(browser.state.value.find); assertEquals(epoch + 1, browser.state.value.surfaceEpoch)
        browser.find("needle")
        val second = lease(browser, BrowserHardwareKey.FIND)
        val queries = engine.events.toList()
        assertTrue(browser.performHardwareKey(second)); assertFalse(browser.performHardwareKey(second))
        assertEquals("needle", browser.state.value.find?.query?.text)
        assertEquals(epoch + 2, browser.state.value.surfaceEpoch); assertEquals(queries, engine.events)
        val blank = newBrowser(backgroundScope, original = space(listOf(first.copy(url = "about:blank")))); runCurrent()
        assertNull(blank.captureHardwareKey(BrowserHardwareKey.FIND, BrowserHardwareKeyHost { true }))
    }
}

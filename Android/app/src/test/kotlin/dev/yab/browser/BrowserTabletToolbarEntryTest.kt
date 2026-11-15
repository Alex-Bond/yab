package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserTabletToolbarEntryTest {
    private val tab = BrowserTab("a", "https://a.test", "A", createdAt = 1)
    private val space = BrowserSpace("s", "Personal", tabs = listOf(tab), currentTabId = tab.id)
    private class Engine : BrowserEngine {
        val events = mutableListOf<String>()
        var readerAccepted = true
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun close(tabId: String) { events += "close:$tabId" }
        override fun goBack(tabId: String) { events += "back:$tabId" }
        override fun goForward(tabId: String) { events += "forward:$tabId" }
        override fun reload(tabId: String) { events += "reload:$tabId" }
        override fun stop(tabId: String) { events += "stop:$tabId" }
        override fun setReader(tabId: String, enabled: Boolean): Boolean {
            events += "reader:$tabId:$enabled"; return readerAccepted
        }
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun newBrowser(scope: CoroutineScope, engine: Engine, original: BrowserSpace = space) =
        BrowserController(object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(original), selectedSpaceId = original.id)
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope, now = { 1 }, newId = { "new" })
    private fun register(browser: BrowserController) {
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(1000.0, 800.0)))
    }
    private fun entry(browser: BrowserController, engine: Engine, environment: () -> Boolean = { true },
        site: PageMenuLease? = null, contextCurrent: () -> Boolean = { true },
        siteCurrent: (PageMenuLease) -> Boolean = { true }): BrowserTabletToolbarEntry {
        val page = BrowserTabletSidebarEntry(browser, checkNotNull(browser.captureTabletSidebarPage(600)),
            BrowserTabletPageEnvironment(environment))
        return checkNotNull(BrowserTabletToolbarEntry.capture(browser, engine, page, browser.state.value,
            browser.tabletToolbarRevision.value, site, retainedContextCurrent = contextCurrent, siteCurrent = siteCurrent))
    }
    private fun control(entry: BrowserTabletToolbarEntry, current: () -> Boolean = { true }) = BrowserTabletToolbarControl(entry, current)

    @Test fun backExitsTheOriginalReaderBeforeNativeHistoryAndNeverFallsBackWhenReaderRefuses() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent(); register(browser)
        browser.pageChanged(tab.id, EnginePageState(readerEnabled = true, canGoBack = true))
        val original = control(entry(browser, engine))
        assertEquals(BrowserTabletToolbarCommand.READER_BACK, original.back)
        val action = checkNotNull(original.command(original.back!!))
        assertTrue(action.perform()); assertFalse(action.perform())
        assertEquals(listOf("reader:a:false"), engine.events)
        engine.readerAccepted = false
        assertFalse(checkNotNull(control(entry(browser, engine)).command(BrowserTabletToolbarCommand.READER_BACK)).perform())
        assertEquals(listOf("reader:a:false", "reader:a:false"), engine.events)
        browser.pageChanged(tab.id, EnginePageState(canGoBack = true))
        val history = control(entry(browser, engine))
        assertEquals(BrowserTabletToolbarCommand.HISTORY_BACK, history.back)
        assertTrue(checkNotNull(history.command(history.back!!)).perform())
        assertEquals("back:a", engine.events.last())
    }

    @Test fun openerBackUsesOnlyTheOriginalSameSpacePublicTargetAndMissingSelfOrDuplicateTargetsDisableIt() = runTest {
        val child = tab.copy(id = "child", openerId = tab.id)
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space.copy(tabs = listOf(tab, child), currentTabId = child.id))
        runCurrent(); register(browser)
        val original = control(entry(browser, engine))
        assertEquals(BrowserTabletToolbarCommand.OPENER_BACK, original.back)
        assertTrue(checkNotNull(original.command(original.back!!)).perform())
        assertEquals(tab.id, browser.state.value.tab?.id)
        assertFalse(browser.state.value.space!!.tabs.any { it.id == child.id })
        assertEquals(listOf("close:child"), engine.events)
        for (target in listOf("missing", child.id)) {
            val otherEngine = Engine()
            val other = newBrowser(backgroundScope, otherEngine, space.copy(tabs = listOf(child.copy(openerId = target)), currentTabId = child.id))
            runCurrent(); register(other)
            assertNull(control(entry(other, otherEngine)).back)
        }
        val duplicateEngine = Engine()
        val duplicate = newBrowser(backgroundScope, duplicateEngine,
            space.copy(tabs = listOf(tab, tab.copy(title = "Same ID"), child), currentTabId = child.id))
        runCurrent(); register(duplicate)
        assertNull(control(entry(duplicate, duplicateEngine)).back)
    }

    @Test fun sameTurnLoadingAbaPermanentlyRefusesTheOriginalTypedReloadAndStopWhileFreshRenderWorks() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent(); register(browser)
        val original = control(entry(browser, engine))
        val reload = checkNotNull(original.command(BrowserTabletToolbarCommand.RELOAD))
        val before = browser.tabletToolbarRevision.value
        browser.pageChanged(tab.id, EnginePageState(loading = true))
        browser.pageChanged(tab.id, EnginePageState(loading = false))
        assertEquals(before + 2, browser.tabletToolbarRevision.value)
        assertFalse(reload.perform()); assertTrue(engine.events.isEmpty())
        assertTrue(checkNotNull(control(entry(browser, engine)).command(BrowserTabletToolbarCommand.RELOAD)).perform())
        browser.pageChanged(tab.id, EnginePageState(loading = true))
        val stop = checkNotNull(control(entry(browser, engine)).command(BrowserTabletToolbarCommand.STOP))
        browser.pageChanged(tab.id, EnginePageState(loading = false))
        browser.pageChanged(tab.id, EnginePageState(loading = true))
        assertFalse(stop.perform())
        val fresh = control(entry(browser, engine))
        assertNull(fresh.command(BrowserTabletToolbarCommand.RELOAD))
        assertTrue(checkNotNull(fresh.command(BrowserTabletToolbarCommand.STOP)).perform())
        assertEquals(listOf("reload:a", "stop:a"), engine.events)
    }

    @Test fun forwardAndReaderRoleAbaRefuseOldCommandsButProgressAndTitleDoNotChangeTheRevocationCounter() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent(); register(browser)
        browser.pageChanged(tab.id, EnginePageState(canGoForward = true))
        val forward = checkNotNull(control(entry(browser, engine)).command(BrowserTabletToolbarCommand.FORWARD))
        browser.pageChanged(tab.id, EnginePageState(canGoForward = false))
        browser.pageChanged(tab.id, EnginePageState(canGoForward = true))
        assertFalse(forward.perform())
        assertTrue(checkNotNull(control(entry(browser, engine)).command(BrowserTabletToolbarCommand.FORWARD)).perform())
        val count = browser.tabletToolbarRevision.value
        browser.pageChanged(tab.id, EnginePageState(canGoForward = true, title = "Fresh", progress = .4f))
        assertEquals(count, browser.tabletToolbarRevision.value)
        browser.pageChanged(tab.id, EnginePageState(canGoForward = true, readerEnabled = true))
        val reader = checkNotNull(control(entry(browser, engine)).command(BrowserTabletToolbarCommand.READER_BACK))
        browser.pageChanged(tab.id, EnginePageState(canGoForward = true))
        browser.pageChanged(tab.id, EnginePageState(canGoForward = true, readerEnabled = true))
        assertFalse(reader.perform()); assertEquals(listOf("forward:a"), engine.events)
    }

    @Test fun allTabsReallyOpensGalleryForOneOriginalTabIncludingBlankAndNeverSubstitutesField() = runTest {
        for (url in listOf(tab.url, "about:blank")) {
            val engine = Engine(); val original = space.copy(tabs = listOf(tab.copy(url = url)))
            val browser = newBrowser(backgroundScope, engine, original); runCurrent(); register(browser)
            val gallery = checkNotNull(control(entry(browser, engine)).gallery())
            assertTrue(gallery.open()); assertFalse(gallery.open())
            assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
            assertEquals(url, browser.state.value.tab?.url)
            assertEquals(listOf(checkNotNull(browser.state.value.tab)), gallery.cards(browser.state.value))
            assertTrue(engine.events.isEmpty())
        }
    }

    @Test fun trueEmptyHasNoInventedNavigationGalleryOrSiteButItsOriginalNewTabUsesTheRealField() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space.copy(tabs = emptyList(), currentTabId = null))
        runCurrent(); register(browser)
        val original = control(entry(browser, engine))
        assertNull(original.back); assertNull(original.reload); assertFalse(original.forwardAvailable)
        assertNull(original.command(BrowserTabletToolbarCommand.ALL_TABS)); assertNull(original.site())
        assertTrue(checkNotNull(original.newTab()).perform())
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        assertTrue(browser.state.value.fieldIsNewTab); assertTrue(engine.events.isEmpty())
    }

    @Test fun originalStopWindowFrontProfilePrivateAccountAndDisposedSceneCannotBorrowAFreshPageAfterReturn() = runTest {
        for (change in listOf("stop", "window", "front", "profile", "private", "account", "scene")) {
            val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent(); register(browser)
            var account = true; var scene = true
            val original = control(entry(browser, engine, { account })) { scene }
            val old = checkNotNull(original.command(BrowserTabletToolbarCommand.RELOAD))
            when (change) {
                "stop" -> { browser.backgrounded(); browser.foregrounded() }
                "window" -> register(browser)
                "front" -> { browser.openUrl("https://b.test", newTab = true); browser.selectTab(tab.id) }
                "profile" -> {
                    val snapshot = checkNotNull(browser.publicSnapshot())
                    browser.applySyncedSnapshot(snapshot.copy(spaces = snapshot.spaces.map { it.copy(ownSignIns = true) }))
                    browser.applySyncedSnapshot(snapshot)
                }
                "private" -> { browser.showPrivate(); browser.selectSpace(space.id) }
                "account" -> { account = false; assertFalse(old.current()); account = true }
                else -> { scene = false; assertFalse(old.current()); scene = true }
            }
            val boundaryEvents = engine.events.toList()
            assertFalse(old.perform()); assertEquals(boundaryEvents, engine.events)
            assertTrue(checkNotNull(control(entry(browser, engine, { account })) { scene }
                .command(BrowserTabletToolbarCommand.RELOAD)).perform())
            assertEquals(boundaryEvents + "reload:a", engine.events)
        }
    }

    @Test fun siteBindsOnlyGenerationOnTheOriginalNativeLeaseAndOwnCoverDoesNotGrantAnyNewPageCommand() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent(); register(browser)
        val native = Any()
        val lease = PageMenuLease("account", 2, tab.id, space.id, space.websiteProfile, native, 0, 0, "device", 3, tab.url, 4)
        var pageOpen = true; var menuOwner = true
        val entry = entry(browser, engine, { pageOpen }, lease, siteCurrent = { menuOwner })
        val site = checkNotNull(control(entry).site())
        val bound = checkNotNull(site.bind(7))
        assertEquals(lease.copy(generation = 7), bound); assertSame(native, bound.nativeOwner)
        assertNull(site.bind(8)); assertFalse(site.current(bound.copy()))
        pageOpen = false
        assertFalse(entry.current()); assertTrue(site.current(bound))
        menuOwner = false; assertFalse(site.current(bound)); menuOwner = true
        assertFalse(site.current(bound))
        assertTrue(engine.events.isEmpty()); assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
    }

    @Test fun currentSourceThatChangesModeDuringTheFinalOwnerReadCannotAuthorizeItsEarlierRole() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent(); register(browser)
        var reads = 0; var armed = false
        val original = entry(browser, engine, {
            if (armed && ++reads == 2) browser.pageChanged(tab.id, EnginePageState(loading = true))
            true
        })
        val action = checkNotNull(original.command(BrowserTabletToolbarCommand.RELOAD))
        reads = 0; armed = true
        assertFalse(action.perform()); assertTrue(engine.events.isEmpty())
    }

    @Test fun captureRejectsStaleRenderedFactsAndReentrantSourceChangesBeforeMintingAnyControl() = runTest {
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine); runCurrent(); register(browser)
        val rendered = browser.state.value
        val revision = browser.tabletToolbarRevision.value
        val page = BrowserTabletSidebarEntry(browser, checkNotNull(browser.captureTabletSidebarPage(600)),
            BrowserTabletPageEnvironment { true })
        browser.pageChanged(tab.id, EnginePageState(loading = true))
        browser.pageChanged(tab.id, EnginePageState())
        assertNull(BrowserTabletToolbarEntry.capture(browser, engine, page, rendered, revision, null, { true }) { true })
        var changed = false
        val reentrant = BrowserTabletSidebarEntry(browser, checkNotNull(browser.captureTabletSidebarPage(600)),
            BrowserTabletPageEnvironment {
                if (!changed) { changed = true; browser.pageChanged(tab.id, EnginePageState(loading = true)) }
                true
            })
        assertNull(BrowserTabletToolbarEntry.capture(browser, engine, reentrant, browser.state.value,
            browser.tabletToolbarRevision.value, null, { true }) { true })
        assertTrue(engine.events.isEmpty())
        assertTrue(checkNotNull(control(entry(browser, engine)).command(BrowserTabletToolbarCommand.STOP)).perform())
        assertEquals(listOf("stop:a"), engine.events)
    }

    @Test fun toolbarBlankCardIsBoundToTheActualGalleryResultAndCannotSurviveWindowAccountEpochUrlOrStopAba() = runTest {
        for (change in listOf("window", "account", "epoch", "url", "stop")) {
            val engine = Engine()
            val browser = newBrowser(backgroundScope, engine, space.copy(tabs = listOf(tab.copy(url = "about:blank"))))
            runCurrent(); register(browser)
            var context = true
            val snapshot = checkNotNull(browser.publicSnapshot())
            val gallery = checkNotNull(control(entry(browser, engine, contextCurrent = { context })).gallery())
            assertTrue(gallery.open())
            val shown = browser.state.value
            assertTrue(shown.galleryTabs.isEmpty()) // Ordinary core policy stays unchanged.
            assertEquals(listOf(shown.tab), gallery.cards(shown)) // A real card, not just an empty surface.
            when (change) {
                "window" -> register(browser)
                "account" -> { context = false; assertFalse(gallery.current()); context = true }
                "epoch" -> { browser.dismissSurface(); browser.show(BrowserSurface.GALLERY) }
                "url" -> {
                    browser.applySyncedSnapshot(snapshot.copy(spaces = snapshot.spaces.map { s ->
                        s.copy(tabs = s.tabs.map { it.copy(url = "https://different.test") })
                    }))
                    browser.applySyncedSnapshot(snapshot)
                }
                else -> { browser.backgrounded(); browser.foregrounded() }
            }
            assertFalse(gallery.current())
            assertTrue(gallery.cards(browser.state.value).isEmpty())
            browser.dismissSurface()
            val fresh = checkNotNull(control(entry(browser, engine, contextCurrent = { context })).gallery())
            assertTrue(fresh.open())
            assertEquals(listOf(browser.state.value.tab), fresh.cards(browser.state.value))
            assertFalse(gallery.current()); assertTrue(engine.events.isEmpty())
        }
    }

    @Test fun mixedBlankFrontIsARealReturnTargetWithoutAdmittingAnotherBlankOrOrdinaryGallery() = runTest {
        val blank = tab.copy(id = "blank", url = "about:blank", title = "New Tab")
        val engine = Engine()
        val browser = newBrowser(backgroundScope, engine, space.copy(tabs = listOf(tab, blank), currentTabId = blank.id))
        runCurrent(); register(browser)
        val source = checkNotNull(control(entry(browser, engine)).gallery())
        assertTrue(source.open())
        val shown = browser.state.value
        assertEquals(listOf(blank, tab), source.cards(shown))
        assertEquals(listOf(tab), shown.galleryTabs)
        assertTrue(source.ownsBlankFront(blank, space.websiteProfile))
        assertFalse(source.ownsBlankFront(blank.copy(id = "other"), space.websiteProfile))
        assertFalse(source.ownsBlankFront(tab, space.websiteProfile))
        browser.finishGallery(space.id, shown.surfaceEpoch, blank.id)
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        assertEquals(blank, browser.state.value.tab)
        assertFalse(source.ownsBlankFront(blank, space.websiteProfile))
        browser.show(BrowserSurface.GALLERY)
        assertEquals(listOf(tab), browser.state.value.privateFrontGalleryCards())
        assertFalse(source.current())
    }

    @Test fun freshGalleryRenderSurvivesCompactWindowReplacementWithoutRevivingItsPageOpenerOrOldReturn() = runTest {
        val blank = tab.copy(id = "blank", url = "about:blank", title = "Tablet empty front")
        val engine = Engine()
        val browser = newBrowser(backgroundScope, engine, space.copy(tabs = listOf(tab, blank), currentTabId = blank.id))
        runCurrent(); register(browser)
        val opener = checkNotNull(control(entry(browser, engine)).gallery())
        assertTrue(opener.open())
        val epoch = browser.state.value.surfaceEpoch
        val first = checkNotNull(BrowserTabletGallerySource.captureGallery(browser, browser.state.value) { true })
        opener.retire()
        val oldReturn = BrowserTabletSidebarAction({ first.ownsBlankFront(blank, space.websiteProfile) }) {
            browser.finishGallery(space.id, epoch, blank.id)
        }
        browser.invalidateWorkspaceWindow()
        assertFalse(first.current()); assertFalse(oldReturn.current())
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(600.0, 1000.0)))
        val compact = checkNotNull(BrowserTabletGallerySource.captureGallery(browser, browser.state.value) { true })
        assertEquals(listOf(blank, tab), compact.cards(browser.state.value))
        assertFalse(compact.open()); assertFalse(opener.open()); assertFalse(opener.current())
        register(browser)
        val returned = checkNotNull(BrowserTabletGallerySource.captureGallery(browser, browser.state.value) { true })
        assertFalse(compact.current()); assertFalse(first.current()); assertFalse(oldReturn.perform())
        assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
        assertEquals(epoch, browser.state.value.surfaceEpoch)
        assertEquals(listOf(blank, tab), returned.cards(browser.state.value))
        val freshReturn = BrowserTabletSidebarAction({ returned.ownsBlankFront(blank, space.websiteProfile) }) {
            browser.finishGallery(space.id, epoch, blank.id)
        }
        assertTrue(freshReturn.perform()); assertFalse(freshReturn.perform())
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        assertEquals(blank, browser.state.value.tab); assertTrue(engine.events.isEmpty())
    }

    @Test fun freshGallerySourcePermanentlyRefusesUnrenderedUrlProfileStopEpochAndAccountAba() = runTest {
        val blank = tab.copy(id = "blank", url = "about:blank")
        for (change in listOf("url", "profile", "stop", "epoch", "account")) {
            val engine = Engine()
            val browser = newBrowser(backgroundScope, engine, space.copy(tabs = listOf(tab, blank), currentTabId = blank.id))
            runCurrent(); register(browser); browser.show(BrowserSurface.GALLERY)
            var account = true
            val original = checkNotNull(BrowserTabletGallerySource.captureGallery(browser, browser.state.value) { account })
            val snapshot = checkNotNull(browser.publicSnapshot())
            when (change) {
                "url" -> {
                    browser.applySyncedSnapshot(snapshot.copy(spaces = snapshot.spaces.map { s -> s.copy(tabs = s.tabs.map {
                        if (it.id == blank.id) it.copy(url = "https://changed.test") else it }) }))
                    browser.applySyncedSnapshot(snapshot)
                }
                "profile" -> {
                    browser.applySyncedSnapshot(snapshot.copy(spaces = snapshot.spaces.map { it.copy(ownSignIns = true) }))
                    browser.applySyncedSnapshot(snapshot)
                }
                "stop" -> { browser.backgrounded(); browser.foregrounded() }
                "epoch" -> { browser.dismissSurface(); browser.show(BrowserSurface.GALLERY) }
                else -> { account = false; assertFalse(original.current()); account = true }
            }
            assertFalse(original.current())
            assertFalse(original.ownsBlankFront(blank, space.websiteProfile))
            val fresh = checkNotNull(BrowserTabletGallerySource.captureGallery(browser, browser.state.value) { account })
            assertTrue(fresh.ownsBlankFront(checkNotNull(browser.state.value.tab), space.websiteProfile))
            assertEquals(listOf(blank, tab), fresh.cards(browser.state.value))
            assertFalse(original.current()); assertEquals(BrowserSurface.GALLERY, browser.state.value.surface)
        }
    }

    @Test fun galleryCaptureRejectsWrongSurfaceEmptyPrivateUnregisteredAndStaleOrReentrantRenderedState() = runTest {
        val blank = tab.copy(url = "about:blank")
        val engine = Engine(); val browser = newBrowser(backgroundScope, engine, space.copy(tabs = listOf(blank)))
        runCurrent()
        assertNull(BrowserTabletGallerySource.captureGallery(browser, browser.state.value) { true })
        browser.show(BrowserSurface.GALLERY)
        assertNull(BrowserTabletGallerySource.captureGallery(browser, browser.state.value) { true })
        register(browser)
        assertNull(BrowserTabletGallerySource.captureGallery(browser, browser.state.value) { false })
        val stale = browser.state.value
        browser.pageChanged(blank.id, EnginePageState(title = "Fresh title"))
        assertNull(BrowserTabletGallerySource.captureGallery(browser, stale) { true })
        val beforeReentrant = browser.state.value
        assertNull(BrowserTabletGallerySource.captureGallery(browser, beforeReentrant) {
            browser.openField(); true
        })
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        browser.show(BrowserSurface.GALLERY)
        val fresh = checkNotNull(BrowserTabletGallerySource.captureGallery(browser, browser.state.value) { true })
        assertTrue(fresh.current()); assertFalse(fresh.open())
        val empty = newBrowser(backgroundScope, Engine(), space.copy(tabs = emptyList(), currentTabId = null))
        runCurrent(); register(empty); empty.show(BrowserSurface.GALLERY)
        assertEquals(BrowserSurface.GALLERY, empty.state.value.surface); assertNull(empty.state.value.tab)
        assertNull(BrowserTabletGallerySource.captureGallery(empty, empty.state.value) { true })
        val other = newBrowser(backgroundScope, Engine(), space.copy(tabs = listOf(blank)))
        runCurrent(); register(other)
        other.openUrl("about:blank", privately = true); other.unlockPrivate(true); other.show(BrowserSurface.GALLERY)
        val privateState = other.state.value
        assertEquals(BrowserSurface.GALLERY, privateState.surface); assertFalse(privateState.privateContentBlocked)
        assertTrue(checkNotNull(privateState.space).isPrivate); assertTrue(checkNotNull(privateState.tab).isPrivate)
        assertTrue(checkNotNull(privateState.space).websiteProfile.isPrivate); assertEquals("about:blank", privateState.tab?.url)
        assertTrue(other.workspaceWindow.value.registered); assertTrue(other.settingsPresentationLifetime.value.active)
        assertNull(BrowserTabletGallerySource.captureGallery(other, privateState) { true })
    }
}

package dev.yab.browser.ui

import dev.yab.browser.engine.SiteConnection
import dev.yab.browser.engine.SitePreferences
import dev.yab.browser.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserTabletSitePopoverTest {
    private val tab = BrowserTab("site-a", "https://site.test/article", "Article", createdAt = 1)
    private val space = BrowserSpace("site-space", "Personal", tabs = listOf(tab), currentTabId = tab.id)
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
    private fun browser(scope: CoroutineScope, selected: BrowserSpace = space) = BrowserController(object : BrowserRepository {
        override suspend fun load() = BrowserSnapshot(spaces = listOf(selected), selectedSpaceId = selected.id)
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }, Engine(), scope, now = { 1 }, newId = { "site-new" })
    private fun register(browser: BrowserController) {
        browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(1000.0, 800.0)))
    }

    private class Opened(val browser: BrowserController, preferences: SitePreferences? = SitePreferences()) {
        private val original = browser.state.value
        private val originalNative = Any()
        var native = originalNative
        var accountEpoch = 2L
        private val originalAccount = accountEpoch
        private val lifetime = browser.settingsPresentationLifetime.value
        private val history = browser.historyPresentationLifetime.value
        private val window = browser.workspaceWindow.value
        private val tab = checkNotNull(original.tab)
        private val space = checkNotNull(original.space)
        val lease = PageMenuLease("site-account", originalAccount, tab.id, space.id, space.websiteProfile,
            originalNative, original.surfaceEpoch, 1, url = tab.url, windowGeneration = window.generation)
        private val geometry = BrowserPageMenuGeometry(1000.0, 800.0, 24.0, PageMenuRect(720.0, 30.0, 44.0, 44.0), 600.0)
        var closes = 0
        val releases = mutableListOf<PageMenuRelease>()
        val entry = BrowserPageMenuEntry(lease, {
            native === originalNative && accountEpoch == originalAccount && lease.ownsSource(browser.state.value, tab.url) &&
                browser.settingsPresentationLifetime.value == lifetime && lifetime.active &&
                browser.historyPresentationLifetime.value == history && browser.workspaceWindow.value == window
        }, { closes++ }, { _, reason -> releases += reason }, { y, _ -> y }, { _, _ -> }, { _, _ -> }, {}, {}, {})
        val session = BrowserPageMenuSession(lease, tab.url, geometry, SpacesRect(0.0, 0.0, 1000.0, 800.0),
            SpacesRect(0.0, 0.0, 1000.0, 800.0), PageMenuContentSnapshot(tab, original.page, preferences,
                (if (tab.url.startsWith("https://")) SiteConnection(true, false, "site.test", null, 0, 0, 0, "site.test", "Fixture", null, null, null) else null), null, null, null, null))
        val state: BrowserTabletSitePopoverState
        init {
            session.entry = entry
            val now = System.nanoTime()
            entry.presentation.open(now, false, false)
            assertTrue(entry.presentation.navigate(PageMenuPage.SITE, now, false, false))
            state = BrowserTabletSitePopoverState(session)
        }
        fun land() {
            entry.presentation.advance(System.nanoTime() + 2_000_000_000L)
            state.complete()
        }
    }

    @Test fun anchoredWidthAndMeasuredInsetHeightStayInsideTheCapturedRootAtBothEdgesAndLargeContent() {
        val left = TabletSitePopoverGeometry(1000.0, 800.0, PageMenuRect(4.0, 30.0, 44.0, 44.0), 24.0)
        val minimum = left.frame(20.0 + 16.0)
        assertEquals(PageMenuRect(8.0, 82.0, 280.0, 44.0), minimum)
        // The actual short32-radius panel normalizes to22; its8pt-inset plate
        // keeps the shared center at14 rather than copying32 or the old minimum12.
        val shortContainer = TabletWorkspaceRect(minimum.x, minimum.y, minimum.width, minimum.height)
        assertEquals(TabletCornerRadii(14.0, 14.0, 14.0, 14.0), TabletConcentricGeometry.inContainer(
            TabletWorkspaceRect(minimum.x + 8, minimum.y + 8, minimum.width - 16, minimum.height - 16), shortContainer, 12.0))
        val right = TabletSitePopoverGeometry(1000.0, 800.0, PageMenuRect(940.0, 30.0, 44.0, 44.0), 24.0)
        assertEquals(PageMenuRect(712.0, 82.0, 280.0, 480.0), right.frame(900.0))
        val lower = TabletSitePopoverGeometry(700.0, 700.0, PageMenuRect(640.0, 560.0, 44.0, 44.0), 24.0).frame(900.0)
        assertEquals(PageMenuRect(412.0, 612.0, 280.0, 80.0), lower)
        assertThrows(IllegalArgumentException::class.java) {
            TabletSitePopoverGeometry(700.0, 700.0, PageMenuRect(640.0, 640.0, 44.0, 44.0), 24.0)
        }
    }

    @Test fun originalBlankSiteStillOwnsItsAvailableActionWhileMissingSitePreferencesCannotAuthorizeDesktop() = runTest {
        val browser = browser(backgroundScope, space.copy(tabs = listOf(tab.copy(url = "about:blank"))))
        runCurrent(); register(browser)
        val opened = Opened(browser, null)
        var shares = 0; var desktop = 0
        assertTrue(opened.state.sourceCurrent())
        assertTrue(opened.state.action(PageMenuPage.SITE, false, false) { shares++ }.perform())
        assertFalse(opened.state.action(PageMenuPage.SITE, false, false,
            { opened.session.snapshot.preferences != null }) { desktop++ }.perform())
        assertEquals(1, shares); assertEquals(0, desktop)
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        assertEquals(PageMenuPage.SITE, opened.state.frame.targetPage)
    }

    @Test fun originalBodyCannotBorrowRestoredStopWindowProfileUrlOrAccountAfterUnrenderedAba() = runTest {
        for (change in listOf("stop", "window", "profile", "url", "account")) {
            val browser = browser(backgroundScope); runCurrent(); register(browser)
            val opened = Opened(browser)
            var writes = 0
            val old = opened.state.action(PageMenuPage.SITE, false, false) { writes++ }
            val snapshot = checkNotNull(browser.publicSnapshot())
            when (change) {
                "stop" -> { browser.backgrounded(); browser.foregrounded() }
                "window" -> register(browser)
                "profile" -> {
                    browser.applySyncedSnapshot(snapshot.copy(spaces = snapshot.spaces.map { it.copy(ownSignIns = true) }))
                    browser.applySyncedSnapshot(snapshot)
                }
                "url" -> {
                    browser.applySyncedSnapshot(snapshot.copy(spaces = snapshot.spaces.map { it.copy(tabs = it.tabs.map { it.copy(url = "https://other.test") }) }))
                    browser.applySyncedSnapshot(snapshot)
                }
                else -> { opened.accountEpoch++; assertFalse(old.enabled()); opened.accountEpoch-- }
            }
            val before = browser.state.value
            assertFalse(old.perform()); assertEquals(0, writes); assertEquals(before, browser.state.value)
            val fresh = Opened(browser)
            assertTrue(fresh.state.action(PageMenuPage.SITE, false, false) { writes++ }.perform())
            assertFalse(old.perform()); assertEquals(1, writes)
        }
    }

    @Test fun closeAndQueuedOriginalExitCompleteOnceAndRetiredSourceCannotDispatchALateAction() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser)
        val opened = Opened(browser)
        val before = browser.state.value
        val exit = opened.state.action(PageMenuPage.SITE, false, true, afterLanding = true) { browser.openField(newTab = false) }
        assertTrue(exit.perform()); assertFalse(exit.perform())
        assertEquals(before, browser.state.value); assertEquals(1, opened.closes)
        opened.land(); opened.land()
        assertEquals(listOf(PageMenuRelease.LANDED), opened.releases)
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        assertFalse(opened.state.closeControl(false, true).perform())
        browser.dismissSurface()
        val stale = Opened(browser)
        var writes = 0
        assertTrue(stale.state.action(PageMenuPage.SITE, false, true, afterLanding = true) { writes++ }.perform())
        browser.backgrounded(); browser.foregrounded()
        stale.entry.presentation.revoke(); stale.state.complete(); stale.state.complete()
        assertEquals(0, writes); assertEquals(listOf(PageMenuRelease.REVOKED), stale.releases)
    }

    @Test fun certificateEightyAndOneSixtyBackUsesLogicalPageAndPermanentlyRetiresTheOldBody() = runTest {
        for (elapsed in listOf(80L, 160L)) {
            val browser = browser(backgroundScope); runCurrent(); register(browser)
            val opened = Opened(browser)
            var writes = 0
            val oldBody = opened.state.action(PageMenuPage.SITE, false, true) { writes++ }
            assertTrue(opened.state.certificate(false, true).perform())
            opened.entry.presentation.advance(System.nanoTime() + elapsed * 1_000_000)
            assertFalse(oldBody.perform())
            val back = opened.state.certificateBack(false, true)
            assertTrue(back.perform()); assertFalse(back.perform())
            assertEquals(PageMenuPage.SITE, opened.state.frame.targetPage)
            assertEquals(2L, opened.state.bodyRevision)
            opened.entry.presentation.advance(System.nanoTime() + 2_000_000_000)
            assertFalse(oldBody.perform())
            assertTrue(opened.state.action(PageMenuPage.SITE, false, false) { writes++ }.perform())
            assertEquals(1, writes)
        }
    }

    @Test fun replacedChoiceAndDisposedControlStayInertWhileFreshUnfocusedChoiceAndFinalSourceCheckRemainUsable() = runTest {
        val browser = browser(backgroundScope); runCurrent(); register(browser)
        val opened = Opened(browser)
        var writes = 0
        var layout = true
        val anchor = TabletSiteChoiceAnchor(PageMenuRect(720.0, 400.0, 44.0, 44.0)) { layout }
        val choiceFrame = anchor.frame(1000.0, 800.0, 4)
        assertEquals(240.0, choiceFrame.width, 0.0)
        assertEquals(444.0, choiceFrame.y, 0.0)
        assertTrue(choiceFrame.right <= 992 && choiceFrame.bottom <= 792)
        val first = TabletSiteChoice.More(anchor); opened.state.choose(first)
        val old = opened.state.action(PageMenuPage.SITE, false, false, { opened.state.choiceCurrent(first) }) { writes++ }
        layout = false
        assertFalse(opened.state.choiceCurrent(first))
        layout = true
        assertFalse(opened.state.choiceCurrent(first))
        opened.state.dismissChoice(first)
        opened.state.choose(TabletSiteChoice.More(TabletSiteChoiceAnchor(anchor.rect) { true }))
        assertFalse(old.perform())
        val current = checkNotNull(opened.state.choice)
        val fresh = opened.state.action(PageMenuPage.SITE, false, false, { opened.state.choiceCurrent(current) }) { writes++ }
        assertTrue(fresh.perform()); fresh.retire(); assertFalse(fresh.perform())
        val reentrant = opened.state.action(PageMenuPage.SITE, false, false, {
            browser.openField(); true
        }) { writes++ }
        assertFalse(reentrant.perform()); assertEquals(1, writes)
    }
}

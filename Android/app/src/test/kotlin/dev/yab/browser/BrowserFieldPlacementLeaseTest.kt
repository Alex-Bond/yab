package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserFieldPlacementLeaseTest {
    private val tab = BrowserTab("a", "https://a.test", "A", createdAt = 1)
    private val initial = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Personal", tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "s")
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
    private fun browser(scope: CoroutineScope): BrowserController {
        var next = 0
        return BrowserController(object : BrowserRepository {
            override suspend fun load() = initial
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, Engine(), scope, now = { 1 }, newId = { "new-${++next}" })
    }
    private fun window(browser: BrowserController) {
        if (!browser.workspaceWindow.value.registered) browser.invalidateWorkspaceWindow()
        assertTrue(browser.commitWorkspaceWindow(browser.workspaceWindow.value.configuration, BrowserWorkspaceWindow(1024.0, 768.0)))
    }
    private fun edit(browser: BrowserController, source: BrowserFieldPlacementLease): (String) -> Boolean {
        val input = source.input
        return { text -> source.current() && input != null && browser.fieldText(text, input) }
    }

    @Test fun actualFieldInputUpdatesAndDraftSurviveSamePlacementAndLocalImeGeometry() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser); browser.openField(newTab = false)
        val source = BrowserFieldPlacementLease.capture(browser, true)
        val write = edit(browser, source)
        assertTrue(write("retained draft"))
        window(browser) // An unchanged full window does not revoke on local IME/root resize.
        assertTrue(source.current()); assertTrue(write("later draft"))
        browser.dismissField(browser.state.value.surfaceEpoch)
        assertFalse(write("stale"))
        browser.openField(newTab = false)
        assertEquals("later draft", browser.state.value.fieldText)
        assertTrue(edit(browser, BrowserFieldPlacementLease.capture(browser, true))("fresh draft"))
    }

    @Test fun configurationAbaAndStaleCommitNeverReauthorizeCapturedInput() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser); browser.openField()
        val source = BrowserFieldPlacementLease.capture(browser, true); val old = edit(browser, source)
        val originalWindow = browser.workspaceWindow.value
        browser.invalidateWorkspaceWindow(); browser.invalidateWorkspaceWindow()
        assertFalse(browser.commitWorkspaceWindow(originalWindow.configuration, originalWindow.geometry!!))
        window(browser)
        assertFalse(old("old")); assertEquals("", browser.state.value.fieldText)
        assertTrue(edit(browser, BrowserFieldPlacementLease.capture(browser, true))("fresh"))
    }

    @Test fun stopAndReturnRequireFreshRenderedInputWithoutDroppingDraft() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser); browser.openField()
        val original = BrowserFieldPlacementLease.capture(browser, true); val old = edit(browser, original)
        assertTrue(old("kept"))
        browser.backgrounded()
        assertFalse(old("away"))
        val away = BrowserFieldPlacementLease.capture(browser, true)
        browser.foregrounded()
        assertFalse(old("returned")); assertFalse(edit(browser, away)("borrowed"))
        assertEquals("kept", browser.state.value.fieldText)
        assertTrue(edit(browser, BrowserFieldPlacementLease.capture(browser, true))("fresh"))
    }

    @Test fun retiredPlacementDoesNotTransferAuthorityWhenEditorMovesAndAccountChanges() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser); browser.openField()
        val tablet = BrowserFieldPlacementLease.capture(browser, true); val old = edit(browser, tablet)
        assertTrue(old("selection state stays outside the placement"))
        val before = browser.state.value
        tablet.retire()
        assertTrue(browser.fieldInputCurrent(tablet.input!!))
        assertFalse(old("revived")); assertEquals(before, browser.state.value)
        val compact = BrowserFieldPlacementLease.capture(browser, false)
        assertTrue(edit(browser, compact)("compact draft"))
        browser.invalidateLocalOwnership(); browser.openField()
        assertFalse(edit(browser, compact)("other account"))
        assertTrue(edit(browser, BrowserFieldPlacementLease.capture(browser, true))("fresh account"))
    }

    @Test fun coalescedPublicPrivatePublicInputCannotReviveOriginalRenderedPlacement() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser); browser.openField()
        val source = BrowserFieldPlacementLease.capture(browser, true); val old = edit(browser, source)
        assertTrue(old("public draft"))
        val epoch = browser.state.value.surfaceEpoch
        browser.fieldPrivacy(true); browser.fieldPrivacy(false) // No composition/collector step between these publications.
        assertEquals(epoch, browser.state.value.surfaceEpoch)
        assertFalse(browser.state.value.fieldIsPrivate)
        assertTrue(browser.fieldInputCurrent(source.input!!))
        assertFalse(source.current()); assertFalse(old("revived public draft"))
        assertEquals("", browser.state.value.fieldText)
        val fresh = BrowserFieldPlacementLease.capture(browser, true)
        assertTrue(edit(browser, fresh)("fresh public draft"))
        assertEquals("fresh public draft", browser.state.value.fieldText)
    }

    @Test fun privateLockAndRestoredFrontUrlRevokeOriginalSourcesBeforePublicationAba() = runTest {
        val browser = browser(backgroundScope); runCurrent(); window(browser); browser.openField(newTab = false)
        val original = BrowserFieldPlacementLease.capture(browser, true); val write = edit(browser, original)
        val before = browser.publicSnapshot()!!
        browser.applySyncedSnapshot(before.copy(spaces = before.spaces.map { space -> space.copy(tabs = space.tabs.map { it.copy(url = "https://b.test") }) }))
        browser.applySyncedSnapshot(before)
        assertTrue(browser.fieldInputCurrent(original.input!!)) // Exact values returned; original generation did not.
        assertFalse(write("old URL"))
        browser.dismissSurface(); browser.showPrivate(); browser.openUrl("https://private.test", newTab = true)
        browser.updateSettings(browser.state.value.settings.copy(lockPrivate = true)); browser.unlockPrivate(true)
        browser.openField(newTab = false)
        val privateSource = BrowserFieldPlacementLease.capture(browser, true)
        browser.lockPrivate(); browser.unlockPrivate(true)
        assertFalse(edit(browser, privateSource)("old Private"))
        assertEquals(BrowserSurface.PAGE, browser.state.value.surface)
        browser.openField(newTab = false)
        assertTrue(edit(browser, BrowserFieldPlacementLease.capture(browser, true))("fresh Private"))
    }
}

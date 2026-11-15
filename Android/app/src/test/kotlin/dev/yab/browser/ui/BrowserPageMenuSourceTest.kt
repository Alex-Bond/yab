package dev.yab.browser.ui

import dev.yab.browser.model.*
import org.junit.Assert.*
import org.junit.Test

class BrowserPageMenuSourceTest {
    private val tab = BrowserTab("menu-tab", "https://menu.fixture.invalid/original", "Original", createdAt = 1)
    private val space = BrowserSpace("menu-space", "Menu", ownSignIns = true, tabs = listOf(tab), currentTabId = tab.id)
    private val state = BrowserState(loading = false, spaces = listOf(space), selectedSpaceId = space.id, surfaceEpoch = 7)
    private val lease = PageMenuLease("synthetic-account", 2, tab.id, space.id, space.websiteProfile, Any(), 7, 3, url = tab.url)

    @Test fun sameSourceMetadataAndKeepRemainLiveButSurfaceProfileUrlFindAndPrivateReplacementRevoke() {
        assertTrue(lease.ownsSource(state, tab.url))
        val kept = tab.copy(place = TabPlace.KEPT, title = "Updated title")
        assertTrue(lease.ownsSource(state.copy(spaces = listOf(space.copy(tabs = listOf(kept)))), tab.url))
        val replacements = listOf(
            state.copy(surfaceEpoch = 8), state.copy(surface = BrowserSurface.FIELD), state.copy(loading = true),
            state.copy(find = BrowserFindState(tab.id, space.websiteProfile, tab.url)),
            state.copy(spaces = listOf(space.copy(ownSignIns = false))),
            state.copy(spaces = listOf(space.copy(tabs = listOf(tab.copy(url = "https://menu.fixture.invalid/other"))))),
            state.copy(spaces = listOf(space.copy(tabs = listOf(tab.copy(id = "replacement")), currentTabId = "replacement"))),
            state.copy(spaces = listOf(space.copy(isPrivate = true, tabs = listOf(tab.copy(isPrivate = true))))),
        )
        replacements.forEach { assertFalse(lease.ownsSource(it, tab.url)) }
        assertFalse(lease.copy(url = "https://menu.fixture.invalid/other").ownsSource(state, tab.url))
    }

    @Test fun capturedSessionRefreshAcceptsOnlyTheSameLiveTabAndKeepsOriginalTextAfterRevocation() {
        val initial = PageMenuContentSnapshot(tab, EnginePageState(), null, null, null, null, null, null)
        val geometry = BrowserPageMenuGeometry(390.0, 844.0, 54.0, PageMenuRect(81.0, 768.0, 228.0, 48.0), 400.0)
        val session = BrowserPageMenuSession(lease, tab.url, geometry, SpacesRect(0.0, 0.0, 390.0, 844.0),
            SpacesRect(0.0, 0.0, 390.0, 844.0), initial)
        val kept = initial.copy(tab = tab.copy(place = TabPlace.KEPT))
        assertTrue(session.update(kept) { true })
        assertEquals(TabPlace.KEPT, session.snapshot.tab.place)
        assertFalse(session.update(kept.copy(tab = tab.copy(title = "Revoked replacement"))) { false })
        assertFalse(session.update(kept.copy(tab = tab.copy(id = "other"))) { true })
        assertFalse(session.update(kept.copy(tab = tab.copy(url = "https://menu.fixture.invalid/other"))) { true })
        assertEquals(tab.title, session.snapshot.tab.title)
        assertEquals(tab.url, session.snapshot.tab.url)
    }
}

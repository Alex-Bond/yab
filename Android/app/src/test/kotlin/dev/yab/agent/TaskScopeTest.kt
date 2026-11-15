package dev.yab.agent

import dev.yab.browser.model.*
import org.junit.Assert.*
import org.junit.Test

class TaskScopeTest {
    private val tab = BrowserTab("tab", "https://site.test/", "Source", createdAt = 1)
    private val public = BrowserState(loading = false, selectedSpaceId = "space", spaces = listOf(BrowserSpace("space", "Public", tabs = listOf(tab), currentTabId = tab.id)))
    @Test fun onlyTheDisplayedPublicSourceCanBecomeATaskOrigin() {
        assertEquals(AgentTaskOrigin("space", "tab", tab.url, tab.title), taskOrigin(public))
        assertEquals(AgentTaskOrigin("space"), taskOrigin(public.copy(surface = BrowserSurface.FIELD, fieldIsNewTab = true)))
        assertNull(taskOrigin(public.copy(loading = true)))
        assertNull(taskOrigin(public.copy(surface = BrowserSurface.FIELD, fieldPrivate = true)))
        assertNull(taskOrigin(public.copy(spaces = listOf(public.space!!.copy(isPrivate = true)))))
        assertNull(taskOrigin(public.copy(spaces = listOf(public.space!!.copy(tabs = listOf(tab.copy(isPrivate = true)))))))
    }
}

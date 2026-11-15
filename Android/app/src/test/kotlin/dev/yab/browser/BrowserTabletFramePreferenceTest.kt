package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import org.junit.Assert.*
import org.junit.Test

class BrowserTabletFramePreferenceTest {
    private val window = WorkspaceWindowState(true, 2, 3, BrowserWorkspaceWindow(1000.0, 800.0))
    private fun capture(owner: BrowserTabletWorkspaceState, source: Any, current: () -> Boolean = { true }) =
        checkNotNull(owner.capture(window, 600, 24.0, true, source, current))

    @Test fun localPreferenceDefaultsTruePersistsFalseAndFreshOwnerRestoresOnlyThatPreference() {
        var stored: Boolean? = null
        fun owner() = BrowserTabletWorkspaceState(stored ?: true) { stored = it; true }
        val firstOwner = owner(); val source = Any(); val first = capture(firstOwner, source)
        assertTrue(first.framed); assertEquals(272.0, first.frame.page.x, 0.0)
        val old = first.frameControl { true }
        assertTrue(old.perform()); assertFalse(old.perform()); assertEquals(false, stored)
        val unframed = capture(firstOwner, source)
        assertFalse(first.layoutCurrent()); assertFalse(unframed.framed)
        assertEquals(264.0, unframed.frame.page.x, 0.0)
        val restored = capture(owner(), Any())
        assertFalse(restored.framed); assertTrue(restored.sidebarShown)
        assertEquals(unframed.frame.page, restored.frame.page)
        assertEquals(window, restored.window)
    }

    @Test fun hiddenFrameAbaStillRetiresOldRowsAndToggleAlthoughTheDrawnPageHasNoRimChange() {
        val owner = BrowserTabletWorkspaceState(); val source = Any()
        val initial = capture(owner, source)
        assertTrue(initial.toggleControl { true }.perform())
        val hidden = capture(owner, source)
        assertFalse(hidden.sidebarShown)
        val oldToggle = hidden.toggleControl { true }
        val oldRow = BrowserTabletSidebarAction(hidden::current) { fail("Old layout cannot act after frame ABA"); false }
        assertTrue(hidden.frameControl { true }.perform())
        val noFrame = capture(owner, source)
        assertEquals(hidden.frame.page, noFrame.frame.page)
        assertTrue(noFrame.frameControl { true }.perform())
        val returned = capture(owner, source)
        assertEquals(hidden.frame.page, returned.frame.page)
        assertFalse(hidden.layoutCurrent()); assertFalse(oldToggle.perform()); assertFalse(oldRow.perform())
        assertTrue(returned.toggleControl { true }.perform())
        assertTrue(capture(owner, source).sidebarShown)
    }

    @Test fun failedPersistencePreservesVisibleValueAndOldOneShotCannotRetryWhileFreshControlCan() {
        var succeeds = false; val writes = mutableListOf<Boolean>()
        val owner = BrowserTabletWorkspaceState { writes += it; succeeds }
        val source = Any(); val first = capture(owner, source)
        val old = first.frameControl { true }
        assertFalse(old.perform()); assertFalse(old.perform())
        assertTrue(owner.framed); assertEquals(listOf(false), writes)
        assertEquals(first.frame, capture(owner, source).frame)
        succeeds = true
        assertTrue(capture(owner, source).frameControl { true }.perform())
        assertFalse(owner.framed); assertEquals(listOf(false, false), writes)
    }

    @Test fun originalSceneRefusalAndAReentrantLayoutChangeCannotPublishAnOldPreferenceCommand() {
        var current = true
        val firstOwner = BrowserTabletWorkspaceState(); val source = Any()
        val first = capture(firstOwner, source)
        val old = first.frameControl { current }
        current = false; assertFalse(old.current()); current = true
        assertFalse(old.perform()); assertTrue(firstOwner.framed)
        lateinit var owner: BrowserTabletWorkspaceState
        var reenter = true; var stored = true
        owner = BrowserTabletWorkspaceState { target ->
            stored = target
            if (reenter) { reenter = false; capture(owner, Any()) }
            true
        }
        val original = capture(owner, source)
        assertFalse(original.frameControl { true }.perform())
        assertFalse(stored) // The local write happened while admitted, before the source changed.
        assertTrue(owner.framed) // No stale layout publication after the reentrant change.
        assertFalse(original.current())
        assertTrue(capture(owner, source).frameControl { true }.perform())
        assertFalse(owner.framed)
    }
}

package dev.yab.browser.ui

import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserState
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.TabPlace
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The sheet's numbers against Field/SearchSheet.swift, on the 402 x 874 screen the iPhone uses. */
class BrowserSearchSheetTest {
    private val geometry = BrowserSheetGeometry(402.0, 874.0, 336.0, 64.0)
    private fun pose(expand: Double, rise: Double = 1.0) = SearchSheetPose(expand, rise, SearchSheet.body(false))

    @Test fun theLowSheetIsFiveRowsOverTheKeyboard() {
        assertEquals(244.0, SearchSheet.body(false), 0.0)
        assertEquals(14.0, SearchSheet.body(true), 0.0)
        assertEquals(874.0 - 336 - (16 + 48 + 8 + 244), geometry.top(pose(0.0)), 0.001)
        assertEquals(40.0, geometry.radius(pose(0.0)), 0.0)
    }

    @Test fun theFieldBecomesTheCapsule() {
        val low = geometry.field(pose(0.0))
        assertEquals(16.0, low.x, 0.0)
        assertEquals(402.0 - 32, low.width, 0.0)
        assertEquals(geometry.top(pose(0.0)) + 16, low.y, 0.001)
        assertEquals(geometry.capsule, geometry.field(pose(1.0)))
        assertEquals(242.0, geometry.capsule.width, 0.0)
        assertEquals(76.0, geometry.capsule.y, 0.0)
    }

    @Test fun rowsLeaveBeforeSpacesArrive() {
        assertTrue(SearchSheet.RowsOut.endInclusive < SearchSheet.SpacesIn.start)
        assertEquals(1.0, SearchSheet.share(.22, SearchSheet.RowsOut), 0.0)
        assertEquals(0.0, SearchSheet.share(.28, SearchSheet.SpacesIn), 0.0)
    }

    @Test fun theSpacesHangUnderTheFieldUntilTheyAreTheWholeScreen() {
        assertEquals(0.0, geometry.hang(pose(1.0)), 0.0)
        assertEquals(0.0, geometry.hidden(pose(1.0)), 0.0)
        assertEquals(geometry.under(pose(0.5)) - geometry.restHead, geometry.hang(pose(0.5)), 0.001)
    }

    @Test fun goingUpTheSheetReachesTheScreensTop() {
        assertTrue(geometry.top(pose(0.0)) > 100)
        val gone = pose(0.0).copy(leave = 1.0)
        assertEquals(0.0, geometry.top(gone), 0.0)
        assertEquals(0.0, geometry.radius(gone), 0.0)
    }

    @Test fun theSheetGrowsOutOfTheControlTapped() {
        val plus = FieldRect(153.0, 780.0, 96.0, 48.0)
        val start = pose(0.0, rise = 0.0).copy(origin = plus)
        assertEquals(plus.x, geometry.field(start).x, 0.0)
        assertEquals(plus.width, geometry.field(start).width, 0.0)
        assertEquals(plus.y, geometry.field(start).y + geometry.drop(start), 0.001)
        assertEquals(0.0, start.grown(SearchSheet.GroundIn), 0.0)
        val end = start.copy(rise = 1.0)
        assertEquals(0.0, geometry.drop(end), 0.0)
        assertEquals(402.0 - 32, geometry.field(end).width, 0.0)
        assertEquals(1.0, end.grown(SearchSheet.RowsIn), 0.0)
        assertEquals(1.0, pose(0.0, rise = 0.0).grown(SearchSheet.RowsIn), 0.0)
    }

    @Test fun droppedTheSheetStandsUnderTheFoot() {
        val low = pose(0.0, rise = 0.0)
        assertEquals(874.0 + SearchSheet.Foot, geometry.top(low) + geometry.drop(low), 0.001)
    }

    @Test fun theStackShowsWhatIsOpen() {
        val pin = BrowserTab(id = "pin", url = "https://a.example/", title = "A", place = TabPlace.PINNED, createdAt = 1)
        val today = BrowserTab(id = "today", url = "https://b.example/", title = "B", createdAt = 1)
        fun state(front: String?, recent: List<String> = emptyList(), tabs: List<BrowserTab> = listOf(pin, today)) =
            BrowserState(loading = false, spaces = listOf(BrowserSpace(id = "s", name = "S", tabs = tabs, currentTabId = front)),
                selectedSpaceId = "s", recency = mapOf("s" to recent))
        // One page in front shows its own card, never +.
        val lone = state("today", tabs = listOf(today)).stackContents()
        assertEquals("today", lone.front?.id); assertTrue(lone.lone)
        // A pin opened here counts as open until closed in All Tabs.
        val opened = state("today", listOf("today", "pin")).stackContents()
        assertEquals("pin", opened.front?.id); assertEquals(2, opened.count); assertFalse(opened.lone)
        // A pin never opened here is the spaces' row, not an open page.
        assertEquals(1, state("today").stackContents().count)
        // Nothing in front: the first of the order is no page being left.
        val empty = state(null).stackContents()
        assertEquals("today", empty.front?.id); assertFalse(empty.lone)
        assertTrue(state(null).emptyHome); assertFalse(state(null).emptyHomeBar)
        assertTrue(state(null, tabs = listOf(pin)).emptyHomeBar)
        assertNull(state(null, tabs = listOf(pin)).stackContents().front)
    }
}

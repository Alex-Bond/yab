package dev.yab.browser

import dev.yab.browser.engine.PinnedSessions
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.TabPlace
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PinnedSessionsTest {
    private fun tab(id: String, place: TabPlace = TabPlace.TODAY) =
        BrowserTab(id = id, url = "https://$id.example/", title = id, place = place, createdAt = 1)
    private val spaces = listOf(
        BrowserSpace(id = "a", name = "A", tabs = listOf(tab("pin", TabPlace.PINNED), tab("today"))),
        BrowserSpace(id = "b", name = "B", tabs = listOf(tab("other-pin", TabPlace.PINNED), tab("other"))))

    @Test fun aPinOfTheSpaceOnScreenStaysAwake() {
        assertTrue(PinnedSessions.of(spaces).holds("pin", "today", memoryPressure = false))
    }

    @Test fun memoryPressureLetsItGo() {
        assertFalse(PinnedSessions.of(spaces).holds("pin", "today", memoryPressure = true))
    }

    @Test fun anotherSpacesPinAndAnyTodayTabCanSleep() {
        val pins = PinnedSessions.of(spaces)
        assertFalse(pins.holds("other-pin", "today", memoryPressure = false))
        assertFalse(pins.holds("today", "pin", memoryPressure = false))
    }
}

package dev.yab.browser

import dev.yab.browser.ui.BrowserSpacePinGrid
import org.junit.Assert.*
import org.junit.Test

class BrowserSpacePinGridTest {
    @Test fun balancesRowsAndKeepsTheSameCollapsedMoreCountAsPhone() {
        assertEquals(BrowserSpacePinGrid(0, 0, 0), BrowserSpacePinGrid.of(0, false))
        assertEquals(BrowserSpacePinGrid(4, 4, 0), BrowserSpacePinGrid.of(4, false))
        assertEquals(BrowserSpacePinGrid(6, 3, 0), BrowserSpacePinGrid.of(6, false))
        assertEquals(BrowserSpacePinGrid(11, 4, 0), BrowserSpacePinGrid.of(11, false))
        assertEquals(BrowserSpacePinGrid(15, 5, 2), BrowserSpacePinGrid.of(16, false))
        assertEquals(BrowserSpacePinGrid(16, 4, 0), BrowserSpacePinGrid.of(16, true))
    }
}

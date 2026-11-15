package dev.yab.browser

import dev.yab.browser.ui.BrowserChromeFold
import org.junit.Assert.*
import org.junit.Test

class BrowserChromeFoldTest {
    @Test fun readingDownThenUpUnfoldsAboveTheTopThreshold() {
        val chrome = BrowserChromeFold()
        assertFalse(chrome.scrolled(49f))
        assertTrue(chrome.scrolled(80f))
        assertTrue(chrome.scrolled(140f))
        // The previous Android expression scrollY > 50 stayed folded here.
        assertFalse(chrome.scrolled(130f))
        assertTrue(chrome.scrolled(160f))
        assertFalse(chrome.scrolled(19f))
    }

    @Test fun subpointSamplesAccumulateWithoutTreatingATrembleAsADirection() {
        val chrome = BrowserChromeFold()
        for (sample in 0..200) chrome.scrolled(sample / 4f)
        assertFalse(chrome.folded)
        for (sample in 201..240) chrome.scrolled(sample / 4f)
        assertTrue(chrome.folded)
        assertTrue(chrome.scrolled(59.5f))
        assertTrue(chrome.scrolled(59f))
        for (sample in 235 downTo 210) chrome.scrolled(sample / 4f)
        assertFalse(chrome.folded)
    }

    @Test fun leavingThePageAndANewPageStartWithAnUnfoldedToolbar() {
        val chrome = BrowserChromeFold()
        chrome.scrolled(300f)
        assertFalse(chrome.unfold())
        assertFalse(chrome.scrolled(0f))
        assertFalse(BrowserChromeFold().folded)
        assertFalse(chrome.scrolled(Float.NaN))
    }
}

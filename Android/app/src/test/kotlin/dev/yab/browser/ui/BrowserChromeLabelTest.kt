package dev.yab.browser.ui

import org.junit.Assert.*
import org.junit.Test

class BrowserChromeLabelTest {
    @Test fun displayKeepsExplicitPortsAndNeverIncludesCredentialsOrThePagePath() {
        val cases = mapOf(
            "https://www.example.com/path?q=private#section" to "example.com",
            "http://WWW.Example.COM:80/path" to "Example.COM:80",
            "https://www.example.com:443/" to "example.com:443",
            "https://user:secret@www.example.com:8443/path" to "example.com:8443",
            "http://127.0.0.1:49281/motion" to "127.0.0.1:49281",
            "http://localhost:3000/" to "localhost:3000",
            "https://xn--mnchen-3ya.de:8443/" to "xn--mnchen-3ya.de:8443",
        )
        cases.forEach { (url, expected) -> assertEquals(url, expected, browserChromeAddress(url)) }
        assertEquals("New Tab", browserChromeAddress(null))
        assertEquals("New Tab", browserChromeAddress("about:blank"))
    }

    @Test fun ipv6DoesNotLoseTheAddressOrItsExplicitPort() {
        val shown = browserChromeAddress("http://[2001:db8::1]:8080/path")
        assertTrue(shown.contains("2001:db8::1"))
        assertTrue(shown.endsWith(":8080"))
        assertFalse(shown.contains("path"))
        // Bracket spelling is additionally checked against actual current Swift output.
    }

    @Test fun scalarLayoutKeepsTheWholeShortWordAndTheEndOfAnOverflowingWord() {
        val short = BrowserChromeLabelPose(41.2, 114.0, 1.0)
        assertEquals(42.0, short.natural, 0.0)
        assertEquals(36.0, short.left, 0.0); assertEquals(0.0, short.fade, 0.0)
        val long = BrowserChromeLabelPose(211.2, 114.0, 1.0)
        assertEquals(212.0, long.natural, 0.0); assertEquals(-98.0, long.left, 0.0)
        assertEquals(long.width, long.left + long.natural, 0.0)
        assertEquals(26.0, long.fade, 0.0)
        val narrow = BrowserChromeLabelPose(160.0, 18.0, 1.0)
        assertEquals(18.0, narrow.fade, 0.0)
        val scaled = BrowserChromeLabelPose(633.6, 342.0, 3.0)
        assertEquals(long.natural * 3, scaled.natural, 0.0)
        assertEquals(long.left * 3, scaled.left, 0.0); assertEquals(78.0, scaled.fade, 0.0)
    }

    @Test fun foldedWordHugUsesTheSameLogicalPointCeilingAsCurrentPhone() {
        assertEquals(104f, BrowserChromePose(1f, 390f, 59.1f).plateWidth, 0f)
        assertEquals(158f, BrowserChromePose(1f, 390f, 200f).plateWidth, 0f)
        assertEquals(62f, BrowserChromePose(1f, 390f, 1f).plateWidth, 0f)
    }

    @Test fun screenEdgeDistanceDoesNotAddTheTransparentNavigationGestureInsetAgain() {
        assertEquals(28f, browserChromeBottom(28f, 48f, 0f), 0f)
        assertEquals(16f, browserChromeBottom(16f, 31f, 0f), 0f)
        // In button navigation, the entire retained touch target clears system-owned taps.
        assertEquals(48f, browserChromeBottom(28f, 48f, 48f), 0f)
        assertEquals(56.5f, browserChromeBottom(16f, 31f, 48f), 0f)
    }
}

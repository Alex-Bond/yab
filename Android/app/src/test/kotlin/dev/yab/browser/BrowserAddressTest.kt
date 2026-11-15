package dev.yab.browser

import dev.yab.browser.model.*
import org.junit.Assert.*
import org.junit.Test

class BrowserAddressTest {
    @Test fun addressesAndQueriesDoNotExecuteOtherSchemes() {
        val settings = BrowserSettings()
        assertEquals("https://example.com/path", BrowserAddress.url("example.com/path", settings))
        assertEquals("https://www.google.com/search?q=hello%20world", BrowserAddress.url("hello world", settings))
        assertTrue(BrowserAddress.url("javascript:alert(1)", settings)!!.startsWith("https://www.google.com/search?q="))
        assertTrue(BrowserAddress.url("file:///private/key", settings)!!.startsWith("https://www.google.com/search?q="))
        assertNull(BrowserAddress.url("  ", settings))
    }

    @Test fun customTemplateCannotVaryOriginOrCredentials() {
        assertTrue(BrowserAddress.validTemplate("https://example.com/?q=%s"))
        assertFalse(BrowserAddress.validTemplate("https://%s.example.com/search"))
        assertFalse(BrowserAddress.validTemplate("https://%s@example.com/search"))
        assertFalse(BrowserAddress.validTemplate("javascript:%s"))
        assertFalse(BrowserAddress.validTemplate("https://example.com/"))
        val invalid = BrowserSettings(searchEngine = SearchEngine.CUSTOM, customSearchTemplate = "https://%s.example.com")
        assertEquals("https://www.google.com/search?q=words", BrowserAddress.url("words", invalid))
    }
}

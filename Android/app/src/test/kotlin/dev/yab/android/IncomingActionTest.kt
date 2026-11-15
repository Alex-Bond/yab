package dev.yab.android

import org.junit.Assert.*
import org.junit.Test

class IncomingActionTest {
    @Test fun externalRoutesCannotAuthorizeOrLoadPrivilegedSchemes() {
        for (url in listOf("javascript:alert(1)", "file:///data/data/dev.yab.android/files/browser.json", "moz-extension://id/options.html", "yab-open://javascript%3Aalert(1)", "https://user:pass@example.com/", "yab://approval/not-an-id")) assertNull(url, IncomingAction.parse(url))
        assertEquals(IncomingAction.Private, IncomingAction.parse("yab://private"))
        assertEquals(IncomingAction.Join("123-456"), IncomingAction.parse("yab://join/123-456"))
    }
    @Test fun wrappedUrlsDecodeOnceAndKeepPlus() {
        assertEquals(IncomingAction.Page("https://example.com/a+b?q=x+y"), IncomingAction.parse("yab-open://https%3A%2F%2Fexample.com%2Fa%2Bb%3Fq%3Dx%2By"))
        assertEquals(IncomingAction.Search("cats and dogs"), IncomingAction.shared("cats and dogs"))
        assertEquals(IncomingAction.SharedPage("https://example.com/"), IncomingAction.shared(" https://example.com/ "))
    }
    @Test fun shareSheetAcceptsOneWebLinkAndCannotDispatchPrivateRoutes() {
        assertEquals(IncomingAction.SharedPage("https://example.com/article"), IncomingAction.shared("An article\nhttps://example.com/article"))
        assertNull(IncomingAction.shared("yab://join/123-456"))
        assertNull(IncomingAction.shared("https://a.example/\nhttps://b.example/"))
        assertNull(IncomingAction.shared("file:///data/data/private"))
    }
    @Test fun nowEntranceKeepsItsOpaqueBindingForAuthenticatedResolution() {
        val address = "yab://now?account=a&device=b&owner=c&fingerprint=d&nonce=e"
        assertEquals(IncomingAction.Now(address), IncomingAction.parse(address))
        assertNull(IncomingAction.shared(address))
    }
}

package dev.yab.browser.download

import org.junit.Assert.*
import org.junit.Test

class OwnedDownloadAttemptTest {
    private val source = OwnedDownloadSource("tab", "container", "native-document", false, "account", 8)
    private val bridge = "00000000-0000-4000-8000-000000000003"
    private val document = "00000000-0000-4000-8000-000000000004"
    private val frame = OwnedDownloadFrame(bridge, document, 10001, 77, "firefox-container-container", false)
    private val request = OwnedDownloadRequest("channel-9", "https://images.example/a.png", "GET", "sub_frame", 10001, 77, 0,
        document, "firefox-default", false)
    private fun armed() = OwnedDownloadAttempt("00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002",
        source, "https://images.example/a.png#shown", 1_000)
    private fun bound() = armed().apply { assertTrue(prepare(bridge, 77, 1, source)); assertTrue(bind(this@OwnedDownloadAttemptTest.frame, 2, source)) }

    @Test fun onlyTheCapturedFrameAndActualGetCanClaimTheAttempt() {
        val changes = listOf(request.copy(method = "POST"), request.copy(method = ""), request.copy(type = "image"),
            request.copy(tab = 10002), request.copy(frame = 78), request.copy(parentFrame = 5), request.copy(parentDocument = bridge),
            request.copy(cookieStore = "firefox-container-container"), request.copy(cookieStore = ""),
            request.copy(cookieStore = "firefox-private"), request.copy(privateOrigin = true), request.copy(url = "https://images.example/b.png"))
        for (wrong in changes) assertFalse("Accepted wrong lineage: $wrong", bound().claim(wrong, 3, source))
        val valid = bound()
        assertTrue(valid.claim(request, 3, source))
        assertFalse("A second request reused the arm", valid.claim(request.copy(id = "second"), 4, source))
    }

    @Test fun aNativePreparedFrameCannotBeReplacedByBackgroundMetadata() {
        assertFalse(armed().bind(frame, 1, source))
        val value = armed(); assertTrue(value.prepare(bridge, 77, 1, source))
        assertFalse(value.bind(frame.copy(frame = 78), 2, source))
        assertFalse(value.bind(frame.copy(bridge = document), 2, source))
        assertFalse(value.bind(frame.copy(cookieStore = "firefox-container-foreign"), 2, source))
        assertFalse(value.bind(frame.copy(cookieStore = "firefox-default"), 2, source))
        assertTrue(value.bind(frame, 2, source))
    }

    @Test fun responseStampNeedsSameRequestAndCannotAuthorizeRedirectOrHtml() {
        fun requested() = bound().apply { assertTrue(claim(this@OwnedDownloadAttemptTest.request, 3, source)) }
        assertFalse(requested().stamp("other", request.url, 200, "image/png", 4, source))
        assertFalse(requested().stamp(request.id, request.url, 302, "image/png", 4, source))
        assertFalse(requested().stamp(request.id, request.url, 200, "text/html", 4, source))
        val value = requested(); assertTrue(value.stamp(request.id, request.url, 200, "image/png", 4, source))
        assertFalse(value.deliver(bridge, request.url, false, 5, source))
        assertFalse(value.deliver(value.stamp, request.url, true, 5, source))
        assertTrue(value.deliver(value.stamp, request.url, false, 5, source))
        assertFalse("The same stream token was consumed twice", value.deliver(value.stamp, request.url, false, 6, source))
    }

    @Test fun accountEpochDocumentAndDeadlineAreCheckedAtEveryBoundary() {
        val replacements = listOf(source.copy(account = "new"), source.copy(accountEpoch = 9), source.copy(document = "replacement"),
            source.copy(tab = "other"), source.copy(profile = "other"), source.copy(privateOrigin = true))
        for (next in replacements) {
            assertFalse(bound().claim(request, 3, next))
            val value = bound(); assertTrue(value.claim(request, 3, source))
            assertFalse(value.stamp(request.id, request.url, 200, "image/png", 4, next))
        }
        assertFalse(bound().claim(request, 1_001, source))
        val value = bound(); value.close(); assertFalse(value.claim(request, 3, source))
    }

    @Test fun twoNativePublicContextsNeverShareAnAuthorityAlthoughWebRequestUsesTheSameWireLabel() {
        val a = source.copy(profile = "context-a")
        val b = source.copy(profile = "context-b", tab = "other-tab", document = "other-native-document")
        val aFrame = frame.copy(cookieStore = "firefox-container-context-a")
        val bFrame = frame.copy(cookieStore = "firefox-container-context-b", tab = 10002, document = bridge, bridge = document)
        fun attempt(owner: OwnedDownloadSource) = OwnedDownloadAttempt("00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002", owner, request.url, 1_000)
        val first = attempt(a); assertTrue(first.prepare(aFrame.bridge, aFrame.frame, 1, a)); assertTrue(first.bind(aFrame, 2, a))
        val second = attempt(b); assertTrue(second.prepare(bFrame.bridge, bFrame.frame, 1, b))
        assertFalse("Another native context's tab label was accepted", second.bind(aFrame.copy(bridge = bFrame.bridge), 2, b))
        assertTrue(second.bind(bFrame, 2, b))
        assertEquals("firefox-default", GeckoImageCookieStores.request(false))
        assertTrue(first.claim(request, 3, a))
        assertFalse("A common wire label became cross-context authority", second.claim(request, 3, b))
        assertTrue(second.claim(request.copy(tab = bFrame.tab, parentDocument = bFrame.document), 3, b))
    }

    @Test fun privateLabelsCannotBecomePublicAndMissingOrUnexpectedLabelsNeverNormalize() {
        val privateSource = source.copy(profile = "private", privateOrigin = true)
        val value = OwnedDownloadAttempt("00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002",
            privateSource, request.url, 1_000)
        val privateFrame = frame.copy(cookieStore = "firefox-private", privateOrigin = true)
        assertTrue(value.prepare(bridge, 77, 1, privateSource))
        assertFalse(value.bind(privateFrame.copy(cookieStore = "firefox-default"), 2, privateSource))
        assertFalse(value.bind(privateFrame.copy(cookieStore = "firefox-container-private"), 2, privateSource))
        assertTrue(value.bind(privateFrame, 2, privateSource))
        assertFalse(value.claim(request.copy(privateOrigin = true), 3, privateSource))
        assertFalse(value.claim(request.copy(cookieStore = "", privateOrigin = true), 3, privateSource))
        assertTrue(value.claim(request.copy(cookieStore = "firefox-private", privateOrigin = true), 3, privateSource))
    }

    @Test fun neverTreatsUnsupportedSchemesOrEmbeddedCredentialsAsBrowserGets() {
        for (url in listOf("blob:https://site.example/id", "data:image/png;base64,eA==", "file:///a.png", "https://user:pass@site.example/a.png"))
            assertNull(url, OwnedDownloadAttempt.resourceUrl(url))
        assertEquals("https://images.example/a.png", OwnedDownloadAttempt.resourceUrl("https://images.example/a.png#shown"))
    }
}

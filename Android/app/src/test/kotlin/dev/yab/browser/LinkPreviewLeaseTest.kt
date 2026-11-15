package dev.yab.browser

import dev.yab.browser.engine.LinkPreviewLease
import dev.yab.browser.engine.linkPreviewWebUrl
import org.junit.Assert.*
import org.junit.Test

class LinkPreviewLeaseTest {
    @Test fun anAccountRejoinCannotReviveARevokedPreview(): Unit {
        var account = "account-a"
        var epoch = 7L
        val lease = LinkPreviewLease { account == "account-a" && epoch == 7L }
        assertTrue(lease.current())
        account = "account-b"; epoch++
        assertFalse(lease.current())
        account = "account-a"; epoch = 7L
        assertFalse(lease.current())
        assertFalse(lease.consume())
    }

    @Test fun documentAndPrivateRevocationCannotBeUndoneByReturningToTheSameTab(): Unit {
        var document = "initial"
        var unlocked = true
        val lease = LinkPreviewLease { document == "initial" && unlocked }
        assertTrue(lease.current())
        unlocked = false
        assertFalse(lease.current())
        unlocked = true; document = "initial"
        assertFalse(lease.current())
        val later = LinkPreviewLease { document == "initial" && unlocked }
        document = "replacement"
        assertFalse(later.consume())
        document = "initial"
        assertFalse(later.consume())
    }

    @Test fun commitIsOnceOnlyAndCloseDoesNotReenterItsFormerOwner(): Unit {
        var reads = 0
        val lease = LinkPreviewLease { reads++; true }
        assertTrue(lease.consume())
        assertFalse(lease.consume())
        lease.close()
        assertFalse(lease.current())
        assertEquals(1, reads)
    }

    @Test fun previewCannotDispatchExternalSchemesOrEmbeddedCredentials(): Unit {
        assertTrue(linkPreviewWebUrl("https://example.com/a?q=1#fragment"))
        assertTrue(linkPreviewWebUrl("http://127.0.0.1:8080/preview"))
        listOf("https://user:secret@example.com/", "javascript:alert(1)", "file:///tmp/private", "data:text/html,hi",
            "blob:https://example.com/id", "intent://example.com/", "about:blank", "//example.com", "https:///missing-host").forEach {
            assertFalse(it, linkPreviewWebUrl(it))
        }
    }
}

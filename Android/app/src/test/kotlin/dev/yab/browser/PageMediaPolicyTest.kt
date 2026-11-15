package dev.yab.browser

import dev.yab.browser.media.*
import org.junit.Assert.*
import org.junit.Test

class PageMediaPolicyTest {
    private val privatePage = PageMediaState(MediaOwner("private-tab", "document", "session", true),
        playing = true, title = "A private title", artist = "A private artist", album = "A private album")

    @Test fun privateSystemExportFollowsTheActualLockSetting() {
        assertFalse(privatePage.mayExport(lockPrivate = true))
        assertTrue(privatePage.mayExport(lockPrivate = false))
        assertTrue(privatePage.copy(owner = privatePage.owner.copy(privateOrigin = false)).mayExport(lockPrivate = true))
        assertFalse(privatePage.copy(active = false).mayExport(lockPrivate = false))
    }

    @Test fun privateSystemMetadataIsGenericWithoutMutatingTheLivePage() {
        val exported = privatePage.systemMetadata()
        assertEquals("Private media", exported.title)
        assertEquals("", exported.artist)
        assertEquals("", exported.album)
        assertEquals(privatePage.owner, exported.owner)
        assertEquals("A private title", privatePage.title)
    }
}

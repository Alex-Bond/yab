package dev.yab.browser.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ContentPermissionPolicyTest {
    private val page = "https://en.wikipedia.org/wiki/Web_browser"

    @Test fun quietRequestsNeverAsk() {
        assertEquals(ContentPermissionAnswer.Allow, ContentPermissionPolicy.answer(ContentPermissionPolicy.AUTOPLAY_INAUDIBLE, page, null))
        assertEquals(ContentPermissionAnswer.Allow, ContentPermissionPolicy.answer(ContentPermissionPolicy.MEDIA_KEY_SYSTEM_ACCESS, page, null))
        for (kind in listOf(ContentPermissionPolicy.AUTOPLAY_AUDIBLE, ContentPermissionPolicy.PERSISTENT_STORAGE, ContentPermissionPolicy.TRACKING, ContentPermissionPolicy.XR))
            assertEquals(ContentPermissionAnswer.Deny, ContentPermissionPolicy.answer(kind, page, null))
    }

    @Test fun questionsNameTheSiteAndWhatItWants() {
        val location = ContentPermissionPolicy.answer(ContentPermissionPolicy.GEOLOCATION, page, null) as ContentPermissionAnswer.Ask
        assertEquals("en.wikipedia.org wants to know where you are.", location.message)
        val cookies = ContentPermissionPolicy.answer(ContentPermissionPolicy.STORAGE_ACCESS, "https://www.example.com/", "https://disqus.com") as ContentPermissionAnswer.Ask
        assertTrue(cookies.message.startsWith("disqus.com wants to use its cookies on example.com"))
        assertTrue(ContentPermissionPolicy.answer(99, null, null) is ContentPermissionAnswer.Ask)
    }
}

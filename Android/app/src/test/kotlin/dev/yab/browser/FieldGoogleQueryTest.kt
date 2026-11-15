package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.*
import org.junit.Test

/** Existing Controller API: also compiled/run against the entire retained baseline tree. */
@OptIn(ExperimentalCoroutinesApi::class)
class FieldGoogleQueryTest {
    private fun controller(url: String, scope: CoroutineScope): BrowserController {
        val tab = BrowserTab("page", url, createdAt = 1)
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("personal", "Personal", tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "personal")
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}; override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}; override fun stop(tabId: String) {}; override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        return BrowserController(object : BrowserRepository {
            override suspend fun load() = snapshot
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope)
    }
    @Test fun googleWordsAreDecodedWhileUnrelatedAddressesStayWhole() = runTest {
        for ((url, expected) in listOf(
            "https://www.google.com/search?q=lisbon+weather" to "lisbon weather",
            "https://google.com/search?q=C%2B%2B+%26+Swift" to "C++ & Swift",
            "https://google.co.uk/search?q=quiet+coffee" to "quiet coffee",
            "https://www.google.ru/search?q=%D0%BF%D0%BE%D0%B3%D0%BE%D0%B4%D0%B0" to "погода",
            "https://google.com.example.net/search?q=words" to "https://google.com.example.net/search?q=words",
            "https://mail.google.com/search?q=words" to "https://mail.google.com/search?q=words",
            "https://google.com/maps?q=words" to "https://google.com/maps?q=words",
            "https://google.com/search?q=one&q=two" to "https://google.com/search?q=one&q=two",
            "https://user@google.com/search?q=words" to "https://user@google.com/search?q=words")) {
            val browser = controller(url, backgroundScope); runCurrent()
            browser.openField(newTab = false)
            assertEquals(url, expected, browser.state.value.fieldText)
        }
    }
    @Test fun editingPreservesDraftAndSubmitKeepsTheOriginalTab() = runTest {
        val browser = controller("https://google.com/search?q=lisbon+weather", backgroundScope); runCurrent()
        browser.openField(newTab = false); assertFalse(browser.state.value.fieldShowsAddress)
        browser.fieldText("lisbon weather october"); browser.dismissSurface(); browser.openField(newTab = false)
        assertEquals("lisbon weather october", browser.state.value.fieldText)
        browser.submitField()
        assertEquals("page", browser.state.value.tab?.id)
        assertEquals("https://www.google.com/search?q=lisbon%20weather%20october", browser.state.value.tab?.url)
    }
    @Test fun aNewPageLeavesUpwardAndTheSameAddressFalls() = runTest {
        val browser = controller("https://ordinary.test", backgroundScope); runCurrent()
        browser.openField(newTab = true); browser.fieldText("https://new.test"); browser.submitField()
        assertTrue(browser.state.value.fieldGoesUp)
        browser.openField(newTab = false)
        assertFalse("a field opens standing", browser.state.value.fieldGoesUp)
        assertTrue(browser.state.value.fieldShowsAddress)
        browser.submitField()
        assertFalse("the same page again falls", browser.state.value.fieldGoesUp)
        browser.openField(newTab = true, privately = true); browser.fieldText("https://private.test"); browser.submitField()
        assertFalse("Private falls", browser.state.value.fieldGoesUp)
    }
    @Test fun privateGoogleWordsReturnWithoutKeepingPrivateEdits() = runTest {
        val browser = controller("https://ordinary.test", backgroundScope); runCurrent()
        browser.openUrl("https://google.com/search?q=private+words", privately = true)
        browser.unlockPrivate(true); browser.openField(newTab = false)
        assertEquals("private words", browser.state.value.fieldText)
        assertTrue(browser.state.value.fieldIsPrivate)
        browser.fieldText("private edit"); browser.dismissSurface(); browser.openField(newTab = false)
        assertEquals("private words", browser.state.value.fieldText)
        assertFalse(browser.publicSnapshot().toString().contains("private edit"))
    }
}

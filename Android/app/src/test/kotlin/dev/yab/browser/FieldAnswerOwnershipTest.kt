package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class FieldAnswerOwnershipTest {
    private class Engine : BrowserEngine {
        var inserted = mutableListOf<String>()
        var captureCount = 0
        override suspend fun captureFieldAnswerTarget(tabId: String): FieldAnswerTarget {
            captureCount++
            return object : FieldAnswerTarget {
                private var consumed = false
                override val ready get() = !consumed
                override suspend fun insert(value: String): Boolean { if (!ready) return false; consumed = true; inserted += value; return true }
                override fun revoke() { consumed = true }
            }
        }
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun repository() = object : BrowserRepository {
        val tabs = listOf(BrowserTab("first", "https://first.test", createdAt = 1), BrowserTab("second", "https://second.test", createdAt = 2))
        override suspend fun load() = BrowserSnapshot(spaces = listOf(BrowserSpace("ordinary", "Ordinary", tabs = tabs, currentTabId = "first")), selectedSpaceId = "ordinary")
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }

    @Test fun typingDoesNotMoveTheCapturedPageAndPasteIsOneShot() = runTest {
        val engine = Engine(); val browser = BrowserController(repository(), engine, backgroundScope); runCurrent()
        browser.openField(newTab = false)
        val target = requireNotNull(browser.captureFieldAnswerTarget())
        browser.fieldText("2400*12")
        assertTrue(target.ready)
        assertTrue(target.insert("28800"))
        assertFalse(target.insert("again"))
        assertEquals(listOf("28800"), engine.inserted)
        assertEquals("first", browser.state.value.tab?.id)
    }

    @Test fun sameAddressReopenedAnotherTabAndIdentityResetRevokeTheOldAction() = runTest {
        val engine = Engine(); val browser = BrowserController(repository(), engine, backgroundScope); runCurrent()
        browser.openField(newTab = false)
        val previous = requireNotNull(browser.captureFieldAnswerTarget())
        browser.openField(newTab = false)
        assertFalse(previous.ready); assertFalse(previous.insert("stale reopen"))
        val tab = requireNotNull(browser.captureFieldAnswerTarget())
        browser.selectTab("second")
        assertFalse(tab.ready); assertFalse(tab.insert("stale tab"))
        browser.openField(newTab = false)
        val account = requireNotNull(browser.captureFieldAnswerTarget())
        browser.invalidateLocalOwnership()
        assertFalse(account.ready); assertFalse(account.insert("stale identity"))
        assertTrue(engine.inserted.isEmpty())
    }

    @Test fun newTabNeverCapturesAndPrivateLockCannotReactivateAnOldBookmark() = runTest {
        val engine = Engine(); val browser = BrowserController(repository(), engine, backgroundScope); runCurrent()
        browser.openField(); assertNull(browser.captureFieldAnswerTarget()); assertEquals(0, engine.captureCount)
        browser.openUrl("https://private.test", privately = true); browser.unlockPrivate(true)
        browser.openField(newTab = false)
        val private = requireNotNull(browser.captureFieldAnswerTarget())
        browser.backgrounded(); assertFalse(private.ready)
        browser.unlockPrivate(true); assertFalse(private.ready); assertFalse(private.insert("after lock"))
        assertTrue(engine.inserted.isEmpty())
    }
}

package dev.yab.browser

import dev.yab.browser.ui.*
import org.junit.Assert.*
import org.junit.Test

class BrowserFieldChatArchiveTest {
    @Test fun retainedActionsNeverAdoptAReplacementAndADisposedOldHostCannotClearTheNewBinding() {
        var owner = true; var firstCalls = 0; var secondCalls = 0
        val binding = BrowserFieldChatArchiveBinding()
        val first = BrowserFieldChatArchiveAction(false, { owner }) { firstCalls++ }
        val second = BrowserFieldChatArchiveAction(true, { true }) { secondCalls++ }
        binding.bind(first); owner = false; binding.bind(second); binding.release(first)
        assertSame(second, binding.action)
        assertFalse(first.perform()); assertEquals(0, firstCalls)
        assertTrue(second.perform()); assertFalse(second.perform()); assertEquals(1, secondCalls)
        binding.close(); binding.bind(first)
        assertNull(binding.action)
    }
}

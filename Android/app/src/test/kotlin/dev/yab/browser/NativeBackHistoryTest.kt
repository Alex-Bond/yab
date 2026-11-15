package dev.yab.browser

import dev.yab.browser.engine.NativeBackHistory
import org.junit.Assert.*
import org.junit.Test

class NativeBackHistoryTest {
    private val first = NativeBackHistory.Page("https://fixture.invalid/first", "First")
    private val second = NativeBackHistory.Page("https://fixture.invalid/second", "Second")
    private val third = NativeBackHistory.Page("https://fixture.invalid/third", "Third")

    @Test fun menuUsesAbsoluteNativeIndexAndRejectsReusedOrModifiedLease() {
        val history = NativeBackHistory()
        val original = mutableListOf(first, second, third)
        history.capture(original, 2)
        original.clear()
        val items = history.items("tab", "document")
        assertEquals(listOf(second.url, first.url), items.map { it.url })
        assertEquals(listOf(1, 2), items.map { it.steps })
        assertNull(history.consume("tab", "document", items.last().copy(url = second.url)))
        assertNull(history.consume("other-tab", "document", items.last()))
        assertNull(history.consume("tab", "other-document", items.last()))
        assertEquals(0, history.consume("tab", "document", items.last()))
        assertNull(history.consume("tab", "document", items.last()))
    }

    @Test fun nativeRevisionCurrentIndexAndRecreatedSessionInvalidateOldMenus() {
        val history = NativeBackHistory()
        history.capture(listOf(first, second, third), 2)
        val before = history.items("tab", "document").first()
        history.capture(listOf(first, second, third), 1)
        assertNull(history.consume("tab", "document", before))
        assertEquals(first.url, history.items("tab", "document").single().url)
        history.capture(listOf(first, second, third.copy(title = "Updated")), 2)
        val restored = NativeBackHistory().apply { capture(listOf(first, second, third), 2) }
        assertNull(restored.consume("tab", "document", before))
        assertEquals(listOf(second.url, first.url), restored.items("tab", "document").map { it.url })
        history.invalidate()
        assertNull(history.consume("tab", "document", before))
    }
}

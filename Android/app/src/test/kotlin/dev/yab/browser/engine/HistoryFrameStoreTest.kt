package dev.yab.browser.engine

import dev.yab.browser.model.HistorySwipeDirection
import org.junit.Assert.*
import org.junit.Test

class HistoryFrameStoreTest {
    private fun row(id: Long, navigation: Long = id) = """{"ID":$id,"docIdentifier":${id + 100},"docshellUUID":"{00000000-0000-0000-0000-000000000001}","navigationId":"00000000-0000-0000-0000-${navigation.toString().padStart(12, '0')}","navigationKey":"00000000-0000-0000-0000-${id.toString().padStart(12, '0')}","url":"https://same.example/"}"""
    private fun state(index: Int, vararg rows: String) = """{"history":{"index":$index,"entries":[${rows.joinToString(",")}]}}"""
    private fun snapshot(index: Int, vararg rows: String) = checkNotNull(HistoryIdentitySnapshot.parse(state(index, *rows)))

    @Test fun sameUrlEntriesRemainDistinctAndUnknownDuplicateOrOversizedIdentityNeverGetsAnImage() {
        val exact = snapshot(2, row(1), row(2))
        assertNotEquals(exact.entries[0], exact.entries[1])
        assertNull(HistoryIdentitySnapshot.parse(state(2, row(1), row(1))))
        assertNull(HistoryIdentitySnapshot.parse(state(1, """{"url":"https://same.example/"}""")))
        assertNull(HistoryIdentitySnapshot.parse(state(3, row(1), row(2))))
        assertNull(HistoryIdentitySnapshot.parse(" ".repeat(262_145)))
        assertNotNull(HistoryIdentitySnapshot.parse(state(1, row(1).replace("\"docIdentifier\":101", "\"docIdentifier\":9007199254740993"))))
    }

    @Test fun oldPageIsNotRenderableUntilExactNativeHistoryProvesItsIdentityAsAnotherEntry() {
        val owner = Any(); val store = HistoryFrameStore<Any>(owner)
        val first = snapshot(1, row(1)); val pixels = Any()
        assertTrue(store.retain(owner, first, 100, 100, 40_000, pixels))
        store.pageStarted()
        assertNull(store.frame(owner, first.entries[0], 100, 100))
        val pushed = snapshot(2, row(1), row(2)); store.historyChanged(owner, pushed)
        assertSame(pixels, store.frame(owner, pushed.entries[0], 100, 100))
        assertNull(store.frame(Any(), pushed.entries[0], 100, 100))
        assertNull(store.frame(owner, pushed.entries[0], 101, 100))
        store.historyChanged(owner, snapshot(1, row(1, navigation = 99)))
        assertEquals(0, store.count)
    }

    @Test fun twoFrameAndAllocationCapsIncludeTheCandidateAndExplicitClearingDropsReferences() {
        val owner = Any(); val store = HistoryFrameStore<Any>(owner)
        for (id in 1L..4L) assertTrue(store.retain(owner, snapshot(1, row(id)), 2048, 2048, 16L * 1024 * 1024, Any()))
        assertEquals(2, store.count); assertEquals(32L * 1024 * 1024, store.bytes)
        assertFalse(store.retain(owner, snapshot(1, row(5)), 2049, 2048, 16L * 1024 * 1024 + 8192, Any()))
        assertFalse(store.retain(Any(), snapshot(1, row(5)), 100, 100, 40_000, Any()))
        store.clear(); assertEquals(0, store.count); assertEquals(0L, store.bytes)
    }

    @Test fun nativeHistoryUsesExactOneUseDirectionIndexAndRevisionNeverUriNavigation() {
        val registry = NativeHistorySwipeRegistry(); val same = "https://same.example/" to "Same"
        registry.update(listOf(same, same, same), 1)
        val back = registry.capture("document", HistorySwipeDirection.BACK)!!
        assertFalse(registry.current("different", back))
        assertEquals(0, registry.consume("document", back)); assertNull(registry.consume("document", back))
        val forward = registry.capture("document", HistorySwipeDirection.FORWARD)!!
        registry.update(listOf(same, same, same), 2)
        assertFalse(registry.current("document", forward))
        assertNull(registry.capture("document", HistorySwipeDirection.FORWARD))
    }

    @Test fun pagerRevocationCannotReleaseTheOnePhysicalCaptureForHistoryUntilNativeCallbackCompletes() {
        val shared = NativeFrameCaptureArbiter(); val pager = PagingCaptureLifetime(shared)
        assertTrue(pager.tryBeginNative()); pager.begin(); pager.invalidate()
        assertNull(shared.acquire())
        pager.nativeFinished()
        val history = shared.acquire()!!
        assertFalse(pager.tryBeginNative()); shared.finish(NativeFrameCaptureArbiter.Ticket())
        assertFalse(pager.tryBeginNative()); shared.finish(history)
        assertTrue(pager.tryBeginNative()); pager.nativeFinished()
    }
}
